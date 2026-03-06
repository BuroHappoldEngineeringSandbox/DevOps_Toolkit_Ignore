using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Text.Json;
using BH.Engine.Test;                       // Modify.Merge, Query.IFullMessage
using BH.Engine.Test.CodeCompliance;        // Compute.RunChecks
using BH.oM.Test;                           // TestStatus
using BH.oM.Test.Results;                   // TestResult, ITestInformation
using BH.oM.Test.CodeCompliance;            // Error, Location, LineSpan, LineLocation
using Error = BH.oM.Test.CodeCompliance.Error; // alias to avoid ambiguity with System

// Lightweight record carrying everything needed for any output format.
public class Annotation
{
    public string   FilePath         { get; set; } = "";
    public int      LineStart        { get; set; }
    public int      LineEnd          { get; set; }
    public int      ColumnStart      { get; set; }
    public int      ColumnEnd        { get; set; }
    /// <summary>"failure" (Error) or "warning" — matches GitHub's expected values.</summary>
    public string   Level            { get; set; } = "warning";
    /// <summary>
    /// Full message including the " - For more information see &lt;url&gt;" suffix,
    /// exactly matching BHoMBot's FullMessage() output.
    /// </summary>
    public string   Message          { get; set; } = "";
    /// <summary>Check method name (e.g. "HasValidCopyright") — used as the SARIF ruleId.</summary>
    public string   RuleName         { get; set; } = "";
    /// <summary>Fully-qualified documentation URL built via BH.Engine.Base.Query.DocumentationURL.</summary>
    public string   DocumentationUrl { get; set; } = "";
    /// <summary>BHoM_Guid from the engine's Error — unique identifier per finding for cross-run tracing.</summary>
    public string   BHoMGuid         { get; set; } = "";
    /// <summary>UTC timestamp at which the engine produced this finding.</summary>
    public DateTime UTCTime          { get; set; }
}

public static class AnnotationConvert
{
    // Compliance checks documentation sub-path — matches FullMessage.cs in CodeComplianceTest_Engine.
    private const string DocsSubPath = "DevOps/Code%20Compliance%20and%20CI/Compliance%20Checks/";

    /// <summary>
    /// Converts an ITestInformation into an Annotation.
    /// Casts directly to BH.oM.Test.CodeCompliance.Error to access all typed properties
    /// without reflection, then delegates message formatting to
    /// BH.Engine.Test.Query.IFullMessage — the same call path BHoMBot used.
    /// </summary>
    public static Annotation ToAnnotationEquivalent(this ITestInformation info)
    {
        var ann = new Annotation();
        ann.Level = info.Status == TestStatus.Error ? "failure" : "warning";

        // IFullMessage dispatches dynamically to the Error-specific overload in
        // CodeComplianceTest_Engine which appends " - For more information see <url>".
        // TrimEnd removes the two trailing newlines that overload adds for PR comment formatting.
        ann.Message = BH.Engine.Test.Query.IFullMessage(info).TrimEnd();

        if (info is Error error)
        {
            ann.RuleName = error.Name ?? "";
            ann.BHoMGuid = error.BHoM_Guid.ToString();
            ann.UTCTime  = error.UTCTime;

            // Build the full URL the same way FullMessage.cs does — via DocumentationURL().
            ann.DocumentationUrl = string.IsNullOrEmpty(error.DocumentationLink)
                ? ""
                : BH.Engine.Base.Query.DocumentationURL(DocsSubPath) + error.DocumentationLink;

            if (error.Location != null)
            {
                ann.FilePath    = error.Location.FilePath ?? "";
                ann.LineStart   = error.Location.Line?.Start?.Line   ?? 0;
                ann.ColumnStart = error.Location.Line?.Start?.Column ?? 0;
                ann.LineEnd     = error.Location.Line?.End?.Line     ?? 0;
                ann.ColumnEnd   = error.Location.Line?.End?.Column   ?? 0;
            }
        }

        return ann;
    }

    /// <summary>Verbose console dump of all fields on a compliance finding.</summary>
    public static void LogDetailedFinding(ITestInformation info)
    {
        if (info == null) return;

        Console.WriteLine("  ---");
        Console.WriteLine($"  Status:    {info.Status}");

        if (info is Error error)
        {
            Console.WriteLine($"  Message:   {error.Message}");
            Console.WriteLine($"  RuleName:  {error.Name}");
            Console.WriteLine($"  DocSlug:   {error.DocumentationLink}");
            Console.WriteLine($"  UTCTime:   {error.UTCTime:dd/MM/yyyy HH:mm:ss}");
            Console.WriteLine($"  BHoM_Guid: {error.BHoM_Guid}");

            if (error.Location != null)
            {
                Console.WriteLine("  Location:");
                Console.WriteLine($"    FilePath:  {error.Location.FilePath}");
                Console.WriteLine($"    Start:     line {error.Location.Line?.Start?.Line}, col {error.Location.Line?.Start?.Column}");
                Console.WriteLine($"    End:       line {error.Location.Line?.End?.Line}, col {error.Location.Line?.End?.Column}");
            }
        }
        else
        {
            // Fallback for any non-Error ITestInformation (future-proofing).
            Console.WriteLine($"  FullMessage: {BH.Engine.Test.Query.IFullMessage(info).TrimEnd()}");
        }
    }
}

/// <summary>Check-type metadata for title/summary/text (mirrors BHoMBot's check outputs).</summary>
static class CheckMetadata
{
    public static void GetOutput(string checkType, TestStatus status,
                                 out string title, out string summary, out string text)
    {
        title = checkType?.ToLowerInvariant() switch
        {
            "code"          => "Check Code Compliance",
            "copyright"     => "Check Copyright Compliance",
            "documentation" => "Check Documentation Compliance",
            _               => "Check Compliance"
        };
        if (status == TestStatus.Error)
        {
            summary = checkType?.ToLowerInvariant() switch
            {
                "code"          => "This check has failed due to compliance errors",
                "copyright"     => "This check has failed due to copyright errors",
                "documentation" => "This check has failed due to documentation errors",
                _               => "This check has failed due to compliance errors"
            };
            text = "There were some compliance issues with the files changed in this Pull Request";
        }
        else if (status == TestStatus.Warning)
        {
            summary = "This check has some warnings";
            text    = "There were some warnings found with the code changed in this Pull Request";
        }
        else
        {
            summary = "";
            text    = "";
        }
    }
}

class Program
{
    static int Main(string[] args)
    {
        // CLI: ComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]
        //                       <code|copyright|documentation> <file1.cs> [file2.cs ...]
        var (outputFormat, sarifFilePath, checkType, files) = ParseArgs(args);
        if (checkType == null || files == null || files.Count == 0)
        {
            Console.WriteLine("Usage:");
            Console.WriteLine("  ComplianceRunner [--output console|github|json|sarif] [--sarif-file PATH]");
            Console.WriteLine("                   <code|copyright|documentation> <file1.cs> [file2.cs ...]");
            Console.WriteLine();
            Console.WriteLine("  --output github  = emit ::error/::warning for GitHub Actions (shows in PR).");
            Console.WriteLine("  --output json    = single JSON object to stdout.");
            Console.WriteLine("  --output sarif   = SARIF 2.1 to stdout (or --sarif-file for a file).");
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
            if (verbose) Console.WriteLine($"\n=== Checking: {file} ===");

            if (!File.Exists(file))
            {
                Console.WriteLine($"  [SKIP] File not found: {file}");
                continue;
            }

            var resultForThisFile = BH.Engine.Test.CodeCompliance.Compute.RunChecks(file, checkType);
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
            var sarif = BuildSarif(checkType, title, allAnnotations);
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

    static (string outputFormat, string? sarifFilePath, string? checkType, List<string>? files)
        ParseArgs(string[] args)
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

        if (rest.Count < 2) return (outputFormat, sarifFilePath, null, null);

        var checkType = rest[0].Trim().ToLowerInvariant();
        if (checkType != "code" && checkType != "copyright" && checkType != "documentation")
            return (outputFormat, sarifFilePath, null, null);

        return (outputFormat, sarifFilePath, checkType, rest.Skip(1).ToList());
    }

    static string BuildSarif(string checkType, string title, List<Annotation> annotations)
    {
        // Build a per-rule entry from distinct rule names so each check method appears
        // as its own rule in Code Scanning, with a helpUri linking to its BHoM docs page.
        var ruleMap = annotations
            .Where(a => !string.IsNullOrEmpty(a.RuleName))
            .GroupBy(a => a.RuleName)
            .ToDictionary(g => g.Key, g => g.First().DocumentationUrl);

        if (ruleMap.Count == 0)
            ruleMap[$"BHoM.{checkType}"] = "";

        var rulesArray = ruleMap.Select(kv =>
        {
            var rule = new Dictionary<string, object>
            {
                ["id"]               = kv.Key,
                ["shortDescription"] = new Dictionary<string, object> { ["text"] = title },
                ["fullDescription"]  = new Dictionary<string, object> { ["text"] = title }
            };
            if (!string.IsNullOrEmpty(kv.Value))
            {
                rule["helpUri"] = kv.Value;
                rule["help"]    = new Dictionary<string, object>
                {
                    ["text"]     = $"For more information see {kv.Value}",
                    ["markdown"] = $"[BHoM documentation]({kv.Value})"
                };
            }
            return (object)rule;
        }).ToArray();

        var results = new List<object>();
        foreach (var a in annotations)
        {
            var ruleId = string.IsNullOrEmpty(a.RuleName) ? $"BHoM.{checkType}" : a.RuleName;

            var region = new Dictionary<string, object>
            {
                ["startLine"] = a.LineStart > 0 ? a.LineStart : 1,
                ["endLine"]   = a.LineEnd   > 0 ? a.LineEnd   : 1
            };
            if (a.ColumnStart > 0) region["startColumn"] = a.ColumnStart;
            if (a.ColumnEnd   > 0) region["endColumn"]   = a.ColumnEnd;

            var props = new Dictionary<string, object>();
            if (!string.IsNullOrEmpty(a.BHoMGuid)) props["bhomGuid"] = a.BHoMGuid;
            if (a.UTCTime != default)               props["utcTime"]  = a.UTCTime.ToString("o");

            var result = new Dictionary<string, object>
            {
                ["ruleId"]    = ruleId,
                ["level"]     = a.Level == "failure" ? "error" : "warning",
                ["message"]   = new Dictionary<string, object> { ["text"] = a.Message },
                ["locations"] = new[]
                {
                    new Dictionary<string, object>
                    {
                        ["physicalLocation"] = new Dictionary<string, object>
                        {
                            ["artifactLocation"] = new Dictionary<string, object>
                            {
                                ["uri"]       = (a.FilePath ?? "").Replace("\\", "/"),
                                ["uriBaseId"] = "%SRCROOT%"
                            },
                            ["region"] = region
                        }
                    }
                }
            };

            if (props.Count > 0)
                result["properties"] = props;

            results.Add(result);
        }

        var sarif = new Dictionary<string, object>
        {
            ["$schema"] = "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
            ["version"] = "2.1.0",
            ["runs"]    = new[]
            {
                new Dictionary<string, object>
                {
                    ["tool"] = new Dictionary<string, object>
                    {
                        ["driver"] = new Dictionary<string, object>
                        {
                            ["name"]           = "BHoM Compliance Runner",
                            ["informationUri"] = BH.Engine.Base.Query.DocumentationURL("DevOps/Code%20Compliance%20and%20CI/Compliance%20Checks/"),
                            ["rules"]          = rulesArray
                        }
                    },
                    ["results"] = results
                }
            }
        };

        return JsonSerializer.Serialize(sarif, new JsonSerializerOptions { WriteIndented = true });
    }
}
