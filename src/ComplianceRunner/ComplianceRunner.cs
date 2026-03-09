using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using BH.Engine.Test;                       // Modify.Merge
using BH.Engine.Test.CodeCompliance;        // Compute.RunChecks
using BH.oM.Test;                           // TestStatus
using BH.oM.Test.Results;                   // TestResult, ITestInformation

class ComplianceRunner
{
    static int Main(string[] args)
    {
        // CLI: ComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]
        //                       [--org-url URL]
        //                       <code|copyright|documentation|project> <file1> [file2 ...]
        var (outputFormat, sarifFilePath, checkType, files, orgUrl) = ParseArgs(args);
        if (checkType == null || files == null || files.Count == 0)
        {
            Console.WriteLine("Usage:");
            Console.WriteLine("  ComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]");
            Console.WriteLine("                   [--org-url REPO_URL]");
            Console.WriteLine("                   <code|copyright|documentation|project> <file1> [file2 ...]");
            Console.WriteLine();
            Console.WriteLine("  --output github  = emit ::error/::warning for GitHub Actions (shows in PR).");
            Console.WriteLine("  --output json    = single JSON object to stdout.");
            Console.WriteLine("  --output sarif   = SARIF 2.1 to stdout (or --sarif-file for a file).");
            Console.WriteLine("  --org-url URL    = repository URL required for 'project' checks");
            Console.WriteLine("                     e.g. https://github.com/BHoM/BHoM_Engine");
            return 1;
        }

        if (outputFormat == "sarif" && !string.IsNullOrEmpty(sarifFilePath))
            outputFormat = "sarif-file";

        bool verbose = outputFormat == "console";
        if (verbose) Console.WriteLine($"Running BHoM {checkType.ToUpper()} compliance...");

        var mergedResult   = new TestResult() { Status = TestStatus.Pass, Information = new List<ITestInformation>() };
        var allAnnotations = new List<Annotation>();

        foreach (var file in files)
        {
            // Each check type is only relevant to certain file extensions.
            if (!IsRelevantFile(file, checkType)) continue;

            if (verbose) Console.WriteLine($"\n=== Checking: {file} ===");

            if (!File.Exists(file))
            {
                Console.WriteLine($"  [SKIP] File not found: {file}");
                continue;
            }

            TestResult resultForThisFile;

            if (checkType == "project")
            {
                if (file.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
                    resultForThisFile = BH.Engine.Test.CodeCompliance.Compute.CheckProjectFile(file, orgUrl);
                else
                    resultForThisFile = BH.Engine.Test.CodeCompliance.Compute.CheckAssemblyInfo(file, orgUrl);

                // Remap absolute location paths back to the relative file path so
                // annotations point to the correct diff line — mirrors BHoMBot ProjectCompliance.cs.
                if (resultForThisFile?.Information != null)
                {
                    resultForThisFile.Information = resultForThisFile.Information
                        .OfType<BH.oM.Test.CodeCompliance.Error>()
                        .Select(e => (ITestInformation)new BH.oM.Test.CodeCompliance.Error
                        {
                            Status            = e.Status,
                            Message           = e.Message,
                            DocumentationLink = e.DocumentationLink,
                            Location          = new BH.oM.Test.CodeCompliance.Location
                            {
                                FilePath = file,
                                Line     = e.Location?.Line
                            }
                        })
                        .ToList();
                }
            }
            else
            {
                resultForThisFile = BH.Engine.Test.CodeCompliance.Compute.RunChecks(file, checkType);
            }

            if (resultForThisFile == null)
            {
                Console.WriteLine($"  [SKIP] No result returned for: {file}");
                continue;
            }

            if (verbose) Console.WriteLine($"  Result Status: {resultForThisFile.Status}");

            mergedResult = mergedResult.Merge(resultForThisFile);

            var information        = resultForThisFile.Information ?? Enumerable.Empty<ITestInformation>();
            var perFileAnnotations = information.Select(i => i.ToAnnotationEquivalent()).ToList();
            var infoList           = information.ToList();

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
                // Message already contains the " - For more information see <url>" suffix.
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
                    ["utcTime"]          = a.UTCTime.ToString("o")  // ISO 8601
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

    static (string outputFormat, string? sarifFilePath, string? checkType, List<string>? files, string orgUrl)
        ParseArgs(string[] args)
    {
        string  outputFormat  = "console";
        string? sarifFilePath = null;
        string  orgUrl        = "";
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
            else if (args[i] == "--org-url" && i + 1 < args.Length)
                orgUrl = args[++i];
            else
                rest.Add(args[i]);
        }

        if (rest.Count < 2) return (outputFormat, sarifFilePath, null, null, orgUrl);

        var checkType = rest[0].Trim().ToLowerInvariant();
        if (checkType != "code" && checkType != "copyright" &&
            checkType != "documentation" && checkType != "project")
            return (outputFormat, sarifFilePath, null, null, orgUrl);

        return (outputFormat, sarifFilePath, checkType, rest.Skip(1).ToList(), orgUrl);
    }

    /// <summary>Returns true when a file should be processed by the given check type.</summary>
    static bool IsRelevantFile(string file, string checkType)
    {
        if (checkType == "project")
            return file.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase) ||
                   Path.GetFileName(file).Equals("AssemblyInfo.cs", StringComparison.OrdinalIgnoreCase);

        // code, copyright, documentation all operate on .cs files.
        return file.EndsWith(".cs", StringComparison.OrdinalIgnoreCase);
    }
}
