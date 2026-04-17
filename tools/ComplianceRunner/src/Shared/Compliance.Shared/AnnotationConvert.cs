using System;
using BH.Engine.Test;                       // Query.IFullMessage
using BH.oM.Test;                           // TestStatus
using BH.oM.Test.Results;                   // ITestInformation
using BH.oM.Test.CodeCompliance;            // Error, Location, LineSpan, LineLocation
using Error = BH.oM.Test.CodeCompliance.Error;

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
        ann.Message = BH.Engine.Test.Query.IFullMessage(info)?.TrimEnd() ?? "";

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
            Console.WriteLine($"  FullMessage: {BH.Engine.Test.Query.IFullMessage(info)?.TrimEnd() ?? ""}");
        }
    }
}
