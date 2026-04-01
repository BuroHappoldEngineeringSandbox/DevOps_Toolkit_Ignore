using NUnit.Framework;

[TestFixture]
public class FileFilterTests
{
    [TestFixture]
    public class IsRelevantFileTests
    {
        [TestCase("code",          "MyClass.cs",            ExpectedResult = true)]
        [TestCase("copyright",     "MyClass.cs",            ExpectedResult = true)]
        [TestCase("documentation", "MyClass.cs",            ExpectedResult = true)]
        [TestCase("code",          "MyClass.CS",            ExpectedResult = true)]   // extension case-insensitive
        [TestCase("code",          "MyProject.csproj",      ExpectedResult = false)]
        [TestCase("code",          "readme.md",             ExpectedResult = false)]
        [TestCase("project",       "MyProject.csproj",      ExpectedResult = true)]
        [TestCase("project",       "MyProject.CSPROJ",      ExpectedResult = true)]  // extension case-insensitive
        [TestCase("project",       "AssemblyInfo.cs",       ExpectedResult = true)]
        [TestCase("project",       "assemblyinfo.cs",       ExpectedResult = true)]  // filename case-insensitive
        [TestCase("project",       "src/AssemblyInfo.cs",   ExpectedResult = true)]  // works with a leading path
        [TestCase("project",       "NotAssemblyInfo.cs",    ExpectedResult = false)]
        [TestCase("project",       "MyClass.cs",            ExpectedResult = false)]
        public bool IsRelevantFile(string checkType, string file)
            => FileFilter.IsRelevantFile(file, checkType);
    }

    [TestFixture]
    public class IsDatasetFileTests
    {
        [TestCase("a/datasets/foo.json",     ExpectedResult = true)]
        [TestCase("a/Datasets/foo.json",     ExpectedResult = true)]  // segment case-insensitive
        [TestCase("a/DATASETS/foo.json",     ExpectedResult = true)]  // segment case-insensitive
        [TestCase(@"a\datasets\foo.json",    ExpectedResult = true)]  // backslash path separators
        [TestCase("a/datasets/foo.JSON",     ExpectedResult = true)]  // extension case-insensitive
        [TestCase("a/notdatasets/foo.json",  ExpectedResult = false)] // no /datasets/ segment
        [TestCase("a/datasets/foo.cs",       ExpectedResult = false)] // wrong extension
        [TestCase("foo.json",                ExpectedResult = false)] // no /datasets/ in path
        [TestCase("datasets/foo.json",       ExpectedResult = false)] // no leading slash — not a segment
        public bool IsDatasetFile(string file)
            => FileFilter.IsDatasetFile(file);
    }
}
