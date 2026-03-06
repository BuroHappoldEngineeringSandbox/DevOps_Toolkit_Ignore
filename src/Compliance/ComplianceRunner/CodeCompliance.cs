using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Text.Json;
using BH.Engine.Test;                  // Modify.Merge (TestResult)
using BH.Engine.Test.CodeCompliance;   // Compute.RunChecks(...)
using BH.oM.Test;                      // TestStatus
using BH.oM.Test.Results;              // TestResult, ITestInformation

// Local annotation type equivalent to BHoMBot's for console/SARIF/Actions use
public class Annotation
{
    public string FilePath { get; set; } = "";
    public int LineStart { get; set; }
    public int LineEnd { get; set; }
    public int ColumnStart { get; set; }
    public int ColumnEnd { get; set; }
    /// <summary>
    /// "failure" (for Error) or "warning" (for Warning) — matches GitHub's expected values
    /// </summary>
    public string Level { get; set; } = "warning";
    public string Message { get; set; } = "";
    /// <summary>
    /// The check method name (e.g. "IsUsingDeprecatedEnumerate") used as the SARIF ruleId.
    /// Falls back to the checkType string when not present.
    /// </summary>
    public string RuleName { get; set; } = "";
    /// <summary>
    /// Documentation URL from MessageAttribute.DocumentationLink — surfaced as SARIF helpUri.
    /// </summary>
    public string DocumentationLink { get; set; } = "";
}

public static class AnnotationConvert
{
    /// <summary>
    /// Converts an ITestInformation (BH.oM.Test.CodeCompliance.Error) into a local Annotation.
    /// Extracts Location.FilePath, Line.Start/End.Line, Line.Start/End.Column,
    /// Name (check method name), and DocumentationLink via reflection.
    /// </summary>
    public static Annotation ToAnnotationEquivalent(this ITestInformation info)
    {
        var ann = new Annotation();

        ann.Level = info.Status == TestStatus.Error ? "failure" : "warning";

        var msgProp = info.GetType().GetProperty("Message");
        ann.Message = msgProp?.GetValue(info)?.ToString() ?? "";

        // Name = method.Name stored by Check.cs via BHoMObject.Name
        var nameProp = info.GetType().GetProperty("Name");
        ann.RuleName = nameProp?.GetValue(info)?.ToString() ?? "";

        // DocumentationLink from MessageAttribute — stored on Error directly
        var docProp = info.GetType().GetProperty("DocumentationLink");
        ann.DocumentationLink = docProp?.GetValue(info)?.ToString() ?? "";

        var locProp = info.GetType().GetProperty("Location");
        var locObj = locProp?.GetValue(info);

        if (locObj != null)
        {
            ann.FilePath = locObj.GetType().GetProperty("FilePath")?.GetValue(locObj)?.ToString() ?? "";

            var lineObj = locObj.GetType().GetProperty("Line")?.GetValue(locObj);
            if (lineObj != null)
            {
                var startObj = lineObj.GetType().GetProperty("Start")?.GetValue(lineObj);
                var endObj   = lineObj.GetType().GetProperty("End")?.GetValue(lineObj);

                if (startObj is { } s)
                {
                    if (s.GetType().GetProperty("Line")?.GetValue(s) is int sl)   ann.LineStart   = sl;
                    if (s.GetType().GetProperty("Column")?.GetValue(s) is int sc) ann.ColumnStart = sc;
                }
                if (endObj is { } e)
                {
                    if (e.GetType().GetProperty("Line")?.GetValue(e) is int el)   ann.LineEnd   = el;
                    if (e.GetType().GetProperty("Column")?.GetValue(e) is int ec) ann.ColumnEnd = ec;
                }
            }
        }

        return ann;
    }

    /// <summary>
    /// Log all available properties from a compliance finding using reflection.
    /// </summary>
    public static void LogDetailedFinding(ITestInformation info)
    {
        if (info == null) return;
        var t = info.GetType();

        Console.WriteLine("  ---");
        Console.WriteLine($"  Status: {info.Status}");
        SafeLogProperty(t, info, "Message",           "Message");
        SafeLogProperty(t, info, "Name",              "RuleName");
        SafeLogProperty(t, info, "DocumentationLink", "DocumentationLink");
        SafeLogProperty(t, info, "Location",          "Location",      v => v?.GetType().FullName ?? "");
        SafeLogProperty(t, info, "UTCTime",           "UTCTime",       v => v is DateTime dt ? dt.ToString("dd/MM/yyyy HH:mm:ss") : (v?.ToString() ?? ""));
        SafeLogProperty(t, info, "BHoM_Guid",         "BHoM_Guid");

        // Location details (nested object)
        var locProp = t.GetProperty("Location");
        var loc = locProp?.GetValue(info);
        if (loc != null)
        {
            var locT = loc.GetType();
            Console.WriteLine("  Location details:");
            SafeLogProperty(locT, loc, "FilePath", "    FilePath");
            var lineObj = locT.GetProperty("Line")?.GetValue(loc);
            if (lineObj != null)
            {
                var lineT  = lineObj.GetType();
                var start  = lineT.GetProperty("Start")?.GetValue(lineObj);
                var end    = lineT.GetProperty("End")?.GetValue(lineObj);
                var startLine   = start?.GetType().GetProperty("Line")?.GetValue(start);
                var startColumn = start?.GetType().GetProperty("Column")?.GetValue(start);
                var endLine     = end?.GetType().GetProperty("Line")?.GetValue(end);
                var endColumn   = end?.GetType().GetProperty("Column")?.GetValue(end);
                Console.WriteLine($"    Start: line {startLine ?? ""}, col {startColumn ?? ""}");
                Console.WriteLine($"    End:   line {endLine   ?? ""}, col {endColumn   ?? ""}");
            }
        }

        SafeLogProperty(t, info, "Fragments",   "Fragments",   v => v?.GetType().FullName ?? "");
        SafeLogProperty(t, info, "Tags",        "Tags",        v => v?.GetType().FullName ?? "");
        SafeLogProperty(t, info, "CustomData",  "CustomData",  v => v?.GetType().FullName ?? "");
    }

    // Nullable format delegate so callers can omit it.
    static void SafeLogProperty(Type type, object instance, string propName, string label, Func<object?, string>? format = null)
    {
        var prop = type.GetProperty(propName);
        if (prop == null) return;
        try
        {
            var value = prop.GetValue(instance);
            string text = format != null ? (format(value) ?? "") : (value?.ToString() ?? "");
            if (!string.IsNullOrEmpty(text) || value != null)
                Console.WriteLine($"  {label}: {text}");
        }
        catch { /* ignore */ }
    }
}

/// <summary>Check-type metadata for title/summary/text (matches legacy BHoMBot).</summary>
static class CheckMetadata
{
    public static void GetOutput(string checkType, TestStatus status, out string title, out string summary, out string text)
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
        // CLI: compliance-runner [--output console|github|json|sarif] [--sarif-file path] <code|copyright|documentation> <file1.cs> [file2.cs ...]
        var (outputFormat, sarifFilePath, checkType, files) = ParseArgs(args);
        if (checkType == null || files == null || files.Count == 0)
        {
            Console.WriteLine("Usage:");
            Console.WriteLine("  compliance-runner [--output console|github|json|sarif] [--sarif-file PATH] <code|copyright|documentation> <file1.cs> [file2.cs ...]");
            Console.WriteLine("  --output github  = emit ::error/::warning for GitHub Actions (shows in PR).");
            Console.WriteLine("  --output json    = single JSON object to stdout.");
            Console.WriteLine("  --output sarif   = SARIF 2.1 to stdout (or to --sarif-file path).");
            return 1;
        }

        if (outputFormat == "sarif" && !string.IsNullOrEmpty(sarifFilePath))
            outputFormat = "sarif-file";

        if (outputFormat == "console")
            Console.WriteLine($"Running BHoM {checkType.ToUpper()} compliance...");

        TestResult mergedResult = new TestResult() { Status = TestStatus.Pass, Information = new List<ITestInformation>() };
        var allAnnotations = new List<Annotation>();

        bool verbose = outputFormat == "console";
        foreach (var file in files)
        {
            if (verbose) Console.WriteLine($"\n=== Checking: {file} ===");

            if (!File.Exists(file))
            {
                Console.WriteLine($"  [SKIP] File not found: {file}");
                continue;
            }

            TestResult resultForThisFile = BH.Engine.Test.CodeCompliance.Compute.RunChecks(file, checkType);
            if (verbose) Console.WriteLine($"  Result Status: {resultForThisFile.Status}");

            mergedResult = mergedResult.Merge(resultForThisFile);

            var information     = resultForThisFile.Information ?? Enumerable.Empty<ITestInformation>();
            var perFileAnnotations = information.Select(info => info.ToAnnotationEquivalent()).ToList();
            var infoList        = information.ToList();

            for (int i = 0; i < perFileAnnotations.Count; i++)
            {
                var a           = perFileAnnotations[i];
                var displayPath = string.IsNullOrEmpty(a.FilePath) ? file : a.FilePath;
                if (verbose)
                {
                    Console.WriteLine($"  - [{a.Level}] {displayPath}:{a.LineStart}:{a.ColumnStart}-{a.LineEnd}:{a.ColumnEnd} [{a.RuleName}] :: {a.Message}");
                    if (!string.IsNullOrEmpty(a.DocumentationLink))
                        Console.WriteLine($"    Docs: {a.DocumentationLink}");
                    if (i < infoList.Count)
                        AnnotationConvert.LogDetailedFinding(infoList[i]);
                }
                allAnnotations.Add(a);
            }
        }

        CheckMetadata.GetOutput(checkType, mergedResult.Status, out string title, out string summary, out string text);
        if (verbose)
        {
            if (mergedResult.Status == TestStatus.Error || mergedResult.Status == TestStatus.Warning)
            {
                Console.WriteLine("\n--- Check output ---");
                Console.WriteLine($"Title: {title}");
                Console.WriteLine($"Summary: {summary}");
                if (!string.IsNullOrEmpty(text)) Console.WriteLine($"Text: {text}");
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
                var msg   = (a.Message ?? "").Replace("\r", "").Replace("\n", " ");
                // Include column when available so GitHub pinpoints the exact symbol
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
                    ["path"]              = a.FilePath,
                    ["lineStart"]         = a.LineStart,
                    ["lineEnd"]           = a.LineEnd,
                    ["columnStart"]       = a.ColumnStart,
                    ["columnEnd"]         = a.ColumnEnd,
                    ["level"]             = a.Level,
                    ["message"]           = a.Message,
                    ["ruleName"]          = a.RuleName,
                    ["documentationLink"] = a.DocumentationLink
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

        return mergedResult.Status == TestStatus.Error ? 1 : 0;
    }

    // Nullable tuple members: sarifFilePath, checkType and files are null on bad input.
    static (string outputFormat, string? sarifFilePath, string? checkType, List<string>? files) ParseArgs(string[] args)
    {
        string outputFormat   = "console";
        string? sarifFilePath = null;
        var rest = new List<string>();
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--output" && i + 1 < args.Length)
            {
                outputFormat = args[++i].ToLowerInvariant();
                if (outputFormat != "console" && outputFormat != "github" && outputFormat != "json" && outputFormat != "sarif")
                    outputFormat = "console";
            }
            else if ((args[i] == "--sarif-file" || args[i] == "--sarif") && i + 1 < args.Length)
            {
                sarifFilePath = args[++i];
            }
            else
                rest.Add(args[i]);
        }
        if (rest.Count < 2) return (outputFormat, sarifFilePath, null, null);
        var checkType = rest[0].Trim().ToLowerInvariant();
        if (checkType != "code" && checkType != "copyright" && checkType != "documentation")
            return (outputFormat, sarifFilePath, null, null);
        var files = rest.Skip(1).ToList();
        return (outputFormat, sarifFilePath, checkType, files);
    }

    static string BuildSarif(string checkType, string title, List<Annotation> annotations)
    {
        // Build a rules array from distinct rule names so each check method appears
        // as its own rule in Code Scanning with its own documentation link.
        var ruleMap = annotations
            .Where(a => !string.IsNullOrEmpty(a.RuleName))
            .GroupBy(a => a.RuleName)
            .ToDictionary(
                g => g.Key,
                g => g.First().DocumentationLink);

        // Fall back to a single generic rule when rule names are unavailable.
        if (ruleMap.Count == 0)
            ruleMap[$"BHoM.{checkType}"] = "";

        var rulesArray = ruleMap.Select(kv =>
        {
            var rule = new Dictionary<string, object>
            {
                ["id"]               = kv.Key,
                ["shortDescription"] = new Dictionary<string, object> { ["text"] = title }
            };
            if (!string.IsNullOrEmpty(kv.Value))
                rule["helpUri"] = kv.Value;
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

            results.Add(new Dictionary<string, object>
            {
                ["ruleId"]    = ruleId,
                ["level"]     = a.Level == "failure" ? "error" : "warning",
                ["message"]   = new Dictionary<string, object> { ["text"] = a.Message ?? "" },
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
            });
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
                            ["informationUri"] = "https://github.com/BHoM/BHoM",
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
