using BH.oM.Test;  // TestStatus

/// <summary>Check-type metadata for the dataset compliance runner.</summary>
static class CheckMetadata
{
    public static void GetOutput(string checkType, TestStatus status,
                                 out string title, out string summary, out string text)
    {
        title = "Check Dataset Compliance";

        if (status == TestStatus.Error)
        {
            summary = "This check has failed due to dataset compliance errors";
            text    = "There were some compliance issues with dataset files changed in this Pull Request";
        }
        else if (status == TestStatus.Warning)
        {
            summary = "This check has some warnings";
            text    = "There were some warnings found with the dataset files changed in this Pull Request";
        }
        else
        {
            summary = "";
            text    = "";
        }
    }
}
