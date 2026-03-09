using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using BH.Engine.Test;                               // Modify.Merge
using BH.Engine.Test.CodeCompliance.DynamicChecks;  // Query.IsValidDataset
using BH.oM.Test;                                   // TestStatus
using BH.oM.Test.Results;                           // TestResult, ITestInformation

class DatasetComplianceRunner
{
    static int Main(string[] args)
    {
        // CLI: DatasetComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]
        //                              <file1.json> [file2.json ...]
        //
        // Only processes .json files whose path contains "datasets" (case-insensitive),
        // mirroring BHoMBot's DatasetCompliance filtering.
        var (outputFormat, sarifFilePath, files) = ParseArgs(args);
        if (files == null || files.Count == 0)
        {
            Console.WriteLine("Usage:");
            Console.WriteLine("  DatasetComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]");
            Console.WriteLine("                          <file1.json> [file2.json ...]");
            Console.WriteLine();
            Console.WriteLine("  --output github  = emit ::error/::warning for GitHub Actions (shows in PR).");
            Console.WriteLine("  --output json    = single JSON object to stdout.");
            Console.WriteLine("  --output sarif   = SARIF 2.1 to stdout (or --sarif-file for a file).");
            return 1;
        }

        if (outputFormat == "sarif" && !string.IsNullOrEmpty(sarifFilePath))
            outputFormat = "sarif-file";

        bool verbose = outputFormat == "console";
        if (verbose) Console.WriteLine("Running BHoM DATASET compliance...");

        var mergedResult   = new TestResult() { Status = TestStatus.Pass, Information = new List<ITestInformation>() };
        var allAnnotations = new List<Annotation>();

        foreach (var file in files)
        {
            // Only .json files under a datasets/ path are in scope.
            if (!IsDatasetFile(file)) continue;

            if (verbose) Console.WriteLine($"\n=== Checking: {file} ===");

            if (!File.Exists(file))
            {
                Console.WriteLine($"  [SKIP] File not found: {file}");
                continue;
            }

            var resultForThisFile = file.IsValidDataset();

            if (verbose) Console.WriteLine($"  Result Status: {resultForThisFile.Status}");

            mergedResult = mergedResult.Merge(resultForThisFile);

            var information        = resultForThisFile.Information ?? Enumerable.Empty<ITestInformation>();
            var perFileAnnotations = information
                .Where(i => i is BH.oM.Test.CodeCompliance.Error)
                .Select(i => i.ToAnnotationEquivalent())
                .ToList();
            var infoList = information.ToList();

            for (int i = 0; i < perFileAnnotations.Count; i++)
            {
                var a           = perFileAnnotations[i];
                var displayPath = string.IsNullOrEmpty(a.FilePath) ? file : a.FilePath;
                if (verbose)
                {
                    Console.WriteLine($"  - [{a.Level}] {displayPath}:{a.LineStart}:{a.ColumnStart}" +
                                      $"-{a.LineEnd}:{a.ColumnEnd} [{a.RuleName}]");
                    Console.WriteLine($"    {a.Message}");
                    if (i < infoList.Count)
                        AnnotationConvert.LogDetailedFinding(infoList[i]);
                }
                allAnnotations.Add(a);
            }
        }

        const string checkType = "dataset";
        CheckMetadata.GetOutput(checkType, mergedResult.Status,
                                out string title, out string summary, out string text);

        if (verbose)
        {
            if (mergedResult.Status == TestStatus.Error || mergedResult.Status == TestStatus.Warning)
            {
                Console.WriteLine("\n--- Check output ---");
                Console.WriteLine($"Title:   {title}");
                Console.WriteLine($"Summary: {summary}");
                if (!string.IsNullOrEmpty(text)) Console.WriteLine($"Text:    {text}");
            }
            Console.WriteLine("\n===============================");
            Console.WriteLine($"FINAL RESULT: {mergedResult.Status} (Annotations: {allAnnotations.Count})");
            Console.WriteLine("===============================");
        }

        if (outputFormat == "github")
        {
            foreach (var a in allAnnotations)
            {
                var path  = string.IsNullOrEmpty(a.FilePath) ? "unknown" : a.FilePath.Replace("\\", "/");
                var level = a.Level == "failure" ? "error" : "warning";
                var msg   = a.Message.Replace("\r", "").Replace("\n", " ");
                var col   = a.ColumnStart > 0 ? $",col={a.ColumnStart}" : "";
                Console.WriteLine($"::{level} file={path},line={a.LineStart}{col}::{msg}");
            }
        }
        else if (outputFormat == "json")
        {
            var payload = new Dictionary<string, object>
            {
                ["status"]          = mergedResult.Status.ToString(),
                ["checkType"]       = checkType,
                ["title"]           = title,
                ["summary"]         = summary,
                ["text"]            = text,
                ["annotationCount"] = allAnnotations.Count,
                ["annotations"]     = allAnnotations.Select(a => new Dictionary<string, object>
                {
                    ["path"]             = a.FilePath,
                    ["lineStart"]        = a.LineStart,
                    ["lineEnd"]          = a.LineEnd,
                    ["columnStart"]      = a.ColumnStart,
                    ["columnEnd"]        = a.ColumnEnd,
                    ["level"]            = a.Level,
                    ["message"]          = a.Message,
                    ["ruleName"]         = a.RuleName,
                    ["documentationUrl"] = a.DocumentationUrl,
                    ["bhomGuid"]         = a.BHoMGuid,
                    ["utcTime"]          = a.UTCTime.ToString("o")
                }).ToList()
            };
            Console.WriteLine(JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = false }));
        }
        else if (outputFormat == "sarif" || outputFormat == "sarif-file")
        {
            var sarif = SarifBuilder.Build(checkType, title, allAnnotations);
            if (outputFormat == "sarif-file" && !string.IsNullOrEmpty(sarifFilePath))
            {
                File.WriteAllText(sarifFilePath, sarif);
                if (verbose) Console.WriteLine($"SARIF written to {sarifFilePath}");
            }
            else
                Console.WriteLine(sarif);
        }

        // Exit code mirrors BHoMBot: failure only on Error; Warning and Pass are both success.
        return mergedResult.Status == TestStatus.Error ? 1 : 0;
    }

    static (string outputFormat, string? sarifFilePath, List<string>? files) ParseArgs(string[] args)
    {
        string  outputFormat  = "console";
        string? sarifFilePath = null;
        var     rest          = new List<string>();

        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--output" && i + 1 < args.Length)
            {
                outputFormat = args[++i].ToLowerInvariant();
                if (outputFormat != "console" && outputFormat != "github" &&
                    outputFormat != "json"    && outputFormat != "sarif")
                    outputFormat = "console";
            }
            else if ((args[i] == "--sarif-file" || args[i] == "--sarif") && i + 1 < args.Length)
                sarifFilePath = args[++i];
            else
                rest.Add(args[i]);
        }

        return rest.Count == 0
            ? (outputFormat, sarifFilePath, null)
            : (outputFormat, sarifFilePath, rest);
    }

    /// <summary>
    /// Returns true for .json files whose path contains a "datasets" segment,
    /// mirroring BHoMBot's DatasetCompliance file filter.
    /// </summary>
    static bool IsDatasetFile(string file) =>
        file.EndsWith(".json", StringComparison.OrdinalIgnoreCase) &&
        file.Replace("\\", "/").Contains("/datasets/", StringComparison.OrdinalIgnoreCase);
}
