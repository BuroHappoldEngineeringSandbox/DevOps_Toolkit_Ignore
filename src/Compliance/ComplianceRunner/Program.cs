using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

// Reference forces compile-time binding, but explicit load ensures runtime binding.
using BH.Engine.Test.CodeCompliance.Checks;

namespace ComplianceRunnerApp
{
    public class Program
    {
        public static int Main(string[] args)
        {
            Console.WriteLine("=== BHoM Compliance Runner ===");

            if (args.Length < 1)
            {
                PrintUsage();
                return 1;
            }

            string inputPath = Path.GetFullPath(args[0]);
            string? onlyRule = null;
            bool verbose = false;
            string? sarifPath = null;

            for (int i = 1; i < args.Length; i++)
            {
                if (args[i] == "--verbose")
                    verbose = true;
                else if (args[i] == "--rule" && i + 1 < args.Length)
                    onlyRule = args[++i];
                else if (args[i] == "--sarif" && i + 1 < args.Length)
                    sarifPath = args[++i];
            }

            // ----------------------------------------------------
            // 1. Explicitly load Test_Toolkit from ProgramData
            // ----------------------------------------------------
            string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            string dllPath = Path.Combine(programData, "BHoM", "Assemblies", "CodeComplianceTest_Engine.dll");

            if (!File.Exists(dllPath))
            {
                Console.WriteLine($"ERROR: Toolkit DLL not found: {dllPath}");
                return 1;
            }

            Assembly.LoadFrom(dllPath);

            // ----------------------------------------------------
            // 2. Resolve loaded assembly
            // ----------------------------------------------------
            var toolkitAssembly = ResolveToolkitAssembly();
            if (toolkitAssembly == null)
            {
                Console.WriteLine("ERROR: CodeComplianceTest_Engine.dll was not loaded.");
                return 1;
            }

            Console.WriteLine($"Loaded Test Toolkit assembly: {toolkitAssembly.Location}");

            var allTypes = toolkitAssembly.GetTypes();

            // ----------------------------------------------------
            // 3. Discover rules via [Message]
            // ----------------------------------------------------
            var ruleMethods =
                (from t in allTypes
                 from m in t.GetMethods(BindingFlags.Public | BindingFlags.Static)
                 let msg = m.GetCustomAttributesData()
                            .FirstOrDefault(a => a.AttributeType.Name == "MessageAttribute")
                 where msg != null
                 select m).ToList();

            Console.WriteLine($"Discovered {ruleMethods.Count} rule(s).");

            // Optional: filter to a single rule
            if (!string.IsNullOrWhiteSpace(onlyRule))
            {
                ruleMethods = ruleMethods.Where(m =>
                    ExtractRuleName(m).Equals(onlyRule, StringComparison.OrdinalIgnoreCase)).ToList();

                Console.WriteLine($"Filtered to rule: {onlyRule}");
            }

            // ----------------------------------------------------
            // 4. Resolve repo root for SARIF
            // ----------------------------------------------------
            string repoRoot =
                Directory.Exists(inputPath)
                ? Path.GetFullPath(inputPath)
                : (Path.GetDirectoryName(inputPath) ?? Environment.CurrentDirectory);

            // ----------------------------------------------------
            // 5. Gather .cs files
            // ----------------------------------------------------
            List<string> csFiles = new();

            if (File.Exists(inputPath) && inputPath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("Single-file mode");
                csFiles.Add(inputPath);
            }
            else if (Directory.Exists(inputPath))
            {
                Console.WriteLine("Directory mode");

                csFiles = Directory.GetFiles(inputPath, "*.cs", SearchOption.AllDirectories)
                                   .Where(f =>
                                       !f.Contains(@"\bin\") &&
                                       !f.Contains(@"\obj\") &&
                                       !f.Contains(@"/bin/") &&
                                       !f.Contains(@"/obj/"))
                                   .ToList();

                Console.WriteLine($"Found {csFiles.Count} C# files");
            }
            else
            {
                Console.WriteLine($"ERROR: Invalid path: {inputPath}");
                return 1;
            }

            // ----------------------------------------------------
            // 6. Run rules
            // ----------------------------------------------------
            var violations = new List<ViolationRecord>();

            foreach (var file in csFiles)
            {
                var tree = CSharpSyntaxTree.ParseText(File.ReadAllText(file), path: file);
                var root = tree.GetRoot();

                foreach (var method in ruleMethods)
                {
                    string ruleName = ExtractRuleName(method);
                    string ruleMessage = ExtractRuleMessage(method);

                    var pathFilters = ExtractPathFilters(method);

                    if (verbose)
                    {
                        Console.WriteLine($"[DEBUG] {ruleName} → {file}");
                        foreach (var pf in pathFilters)
                        {
                            bool match = pf.Regex.IsMatch(file.Replace('/', '\\'));
                            Console.WriteLine($"   PathFilter: {pf.Regex} | Include={pf.Include} | Match={match}");
                        }
                    }

                    if (!PathAllowsFile(pathFilters, file))
                    {
                        if (verbose) Console.WriteLine("   Skipped: path mismatch\n");
                        continue;
                    }

                    var parameters = method.GetParameters();
                    if (parameters.Length != 1) continue;

                    var paramType = parameters[0].ParameterType;

                    var nodes = root.DescendantNodesAndSelf()
                                    .Where(n => paramType.IsInstanceOfType(n));

                    foreach (var node in nodes)
                    {
                        object? result = null;

                        try
                        {
                            result = method.Invoke(null, new object[] { node });
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"ERROR running {ruleName}: {ex.Message}");
                        }

                        if (result != null)
                        {
                            var loc = node.GetLocation().GetLineSpan();
                            int line = loc.StartLinePosition.Line + 1;

                            Console.WriteLine($"❌ {ruleName}");
                            Console.WriteLine($"    {ruleMessage}");
                            Console.WriteLine($"    {file}:{line}");
                            Console.WriteLine();

                            violations.Add(new ViolationRecord
                            {
                                Rule = ruleName,
                                Message = ruleMessage,
                                File = ToRelative(file, repoRoot),
                                Line = line
                            });
                        }
                    }
                }
            }

            // ----------------------------------------------------
            // 7. Write SARIF
            // ----------------------------------------------------
            if (!string.IsNullOrWhiteSpace(sarifPath))
            {
                try
                {
                    SarifWriter.WriteSarif(sarifPath!, violations, repoRoot);
                    Console.WriteLine($"SARIF written to: {sarifPath}");
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"ERROR writing SARIF: {ex.Message}");
                }
            }

            // ----------------------------------------------------
            // 8. Exit code
            // ----------------------------------------------------
            Console.WriteLine();
            if (violations.Count > 0)
            {
                Console.WriteLine($"=== Compliance FAILED: {violations.Count} ===");
                return 1;
            }

            Console.WriteLine("=== Compliance PASSED ===");
            return 0;
        }

        // =======================================================
        // Assembly resolution
        // =======================================================
        private static Assembly? ResolveToolkitAssembly()
        {
            return AppDomain.CurrentDomain.GetAssemblies()
                .FirstOrDefault(a =>
                    a.GetName().Name.Equals("CodeComplianceTest_Engine",
                        StringComparison.OrdinalIgnoreCase));
        }

        // =======================================================
        // Rule helpers
        // =======================================================
        private static string ExtractRuleName(MethodInfo method)
        {
            var msg = method
                .GetCustomAttributesData()
                .First(a => a.AttributeType.Name == "MessageAttribute");

            return msg.ConstructorArguments.Count > 1
                ? (msg.ConstructorArguments[1].Value?.ToString() ?? method.Name)
                : method.Name;
        }

        private static string ExtractRuleMessage(MethodInfo method)
        {
            var msg = method
                .GetCustomAttributesData()
                .First(a => a.AttributeType.Name == "MessageAttribute");

            return msg.ConstructorArguments[0].Value?.ToString() ?? "Violation";
        }

        private static List<PathFilter> ExtractPathFilters(MethodInfo method)
        {
            return method.GetCustomAttributesData()
                         .Where(a => a.AttributeType.Name == "PathAttribute")
                         .Select(attr =>
                         {
                             string pattern = attr.ConstructorArguments[0].Value?.ToString() ?? ".*";
                             bool include = attr.ConstructorArguments.Count == 1 ||
                                            (bool)attr.ConstructorArguments[1].Value!;
                             return new PathFilter(pattern, include);
                         })
                         .ToList();
        }

        private static bool PathAllowsFile(List<PathFilter> filters, string file)
        {
            if (filters.Count == 0) return true;

            string norm = file.Replace('/', '\\');

            var includes = filters.Where(f => f.Include);
            var excludes = filters.Where(f => !f.Include);

            bool includeOK = !includes.Any() || includes.Any(f => f.Regex.IsMatch(norm));
            bool excludeHit = excludes.Any(f => f.Regex.IsMatch(norm));

            return includeOK && !excludeHit;
        }

        public static string ToRelative(string path, string root)
        {
            string full = Path.GetFullPath(path);
            string rootNorm = Path.GetFullPath(root).TrimEnd('\\', '/');

            return full.StartsWith(rootNorm, StringComparison.OrdinalIgnoreCase)
                ? full.Substring(rootNorm.Length).TrimStart('\\', '/')
                : path;
        }

        // =======================================================
        // UI
        // =======================================================
        private static void PrintUsage()
        {
            Console.WriteLine("Usage:");
            Console.WriteLine("  ComplianceRunner <repo-or-file> [--rule Name] [--verbose] [--sarif out.sarif]");
        }
    }

    // ===========================================================
    // Supporting types
    // ===========================================================

    public class ViolationRecord
    {
        public string Rule { get; set; } = "";
        public string Message { get; set; } = "";
        public string File { get; set; } = "";
        public int Line { get; set; }
    }

    public class PathFilter
    {
        public Regex Regex { get; }
        public bool Include { get; }

        public PathFilter(string pattern, bool include)
        {
            Regex = new Regex(pattern, RegexOptions.Compiled | RegexOptions.IgnoreCase);
            Include = include;
        }
    }

    public static class SarifWriter
    {
        public static void WriteSarif(string outputPath, List<ViolationRecord> violations, string repoRoot)
        {
            string ToSarifPath(string path) =>
                ComplianceRunnerApp.Program.ToRelative(path, repoRoot).Replace("\\", "/");

            var sarif = new
            {
                version = "2.1.0",
                schema = "https://json.schemastore.org/sarif-2.1.0.json",
                runs = new[]
                {
                    new
                    {
                        tool = new
                        {
                            driver = new
                            {
                                name = "BHoM Compliance Runner",
                                version = "1.0.0",
                                rules = violations
                                    .GroupBy(v => v.Rule)
                                    .Select(g => new
                                    {
                                        id = g.Key,
                                        shortDescription = new { text = g.First().Message }
                                    }).ToArray()
                            }
                        },
                        results = violations.Select(v => new
                        {
                            ruleId  = v.Rule,
                            message = new { text = v.Message },
                            level   = "error",
                            locations = new[]
                            {
                                new
                                {
                                    physicalLocation = new
                                    {
                                        artifactLocation = new { uri = ToSarifPath(v.File) },
                                        region = new { startLine = v.Line, startColumn = 1 }
                                    }
                                }
                            }
                        }).ToArray()
                    }
                }
            };

            File.WriteAllText(
                outputPath,
                JsonSerializer.Serialize(
                    sarif,
                    new JsonSerializerOptions { WriteIndented = true })
            );
        }
    }
}