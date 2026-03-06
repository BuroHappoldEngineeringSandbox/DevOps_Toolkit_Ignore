using BH.oM.Test;  // TestStatus

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
