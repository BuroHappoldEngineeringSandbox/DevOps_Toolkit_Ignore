using BH.oM.Test;

/// <summary>Check-type metadata for title/summary/text (mirrors BHoMBot's check outputs).</summary>
public static class CheckMetadata
{
    public static void GetOutput(string? checkType, TestStatus status,
                                 out string title, out string summary, out string text)
    {
        title = checkType?.ToLowerInvariant() switch
        {
            "code"          => "Check Code Compliance",
            "copyright"     => "Check Copyright Compliance",
            "documentation" => "Check Documentation Compliance",
            "project"       => "Check Project Compliance",
            "dataset"       => "Check Dataset Compliance",
            _               => "Check Compliance"
        };

        if (status == TestStatus.Error)
        {
            summary = checkType?.ToLowerInvariant() switch
            {
                "code"          => "This check has failed due to compliance errors",
                "copyright"     => "This check has failed due to copyright errors",
                "documentation" => "This check has failed due to documentation errors",
                "project"       => "This check has failed due to project compliance errors",
                "dataset"       => "This check has failed due to dataset compliance errors",
                _               => "This check has failed due to compliance errors"
            };
            text = checkType?.ToLowerInvariant() switch
            {
                "project" => "There were some compliance issues with either the .csproj or AssemblyInfo files changed in this Pull Request",
                "dataset" => "There were some compliance issues with dataset files changed in this Pull Request",
                _         => "There were some compliance issues with the files changed in this Pull Request"
            };
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
