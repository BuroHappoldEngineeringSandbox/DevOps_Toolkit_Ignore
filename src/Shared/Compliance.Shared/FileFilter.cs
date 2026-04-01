/// <summary>File-extension and path filters for compliance runners.</summary>
public static class FileFilter
{
    /// <summary>Returns true when a file should be processed by the given compliance check type.</summary>
    public static bool IsRelevantFile(string file, string checkType)
    {
        if (checkType == "project")
            return file.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase) ||
                   Path.GetFileName(file).Equals("AssemblyInfo.cs", StringComparison.OrdinalIgnoreCase);

        // code, copyright, documentation all operate on .cs files.
        return file.EndsWith(".cs", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Returns true for .json files whose path contains a "datasets" segment,
    /// mirroring BHoMBot's DatasetCompliance file filter.
    /// </summary>
    public static bool IsDatasetFile(string file) =>
        file.EndsWith(".json", StringComparison.OrdinalIgnoreCase) &&
        file.Replace("\\", "/").Contains("/datasets/", StringComparison.OrdinalIgnoreCase);
}
