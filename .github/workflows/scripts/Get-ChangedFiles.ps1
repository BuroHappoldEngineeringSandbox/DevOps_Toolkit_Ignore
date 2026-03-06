param(
    [Parameter(Mandatory)][string]$EventName,
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$OutputFile = "changed_files.txt"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EventName -ne "pull_request") {
    "count=0" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    exit 0
}

git fetch origin $BaseRef

$files = git diff --name-only --diff-filter=ACMRT "origin/$BaseRef...HEAD" |
         Where-Object { $_.ToLower().EndsWith(".cs") }

$count = ($files | Measure-Object).Count
$files -join "`n" | Out-File $OutputFile -Encoding utf8

"count=$count" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

if ($count -gt 0) {
    Write-Host "Changed C# files ($count):"
    Get-Content $OutputFile
} else {
    Write-Host "No changed C# files detected."
}
