# run-checks.ps1 — runs BHoM compliance checks and exports SARIF files per check.
# Expects: cwd = caller repo root, changed files list at -FileListPath.
#
# Writes to GITHUB_OUTPUT:  sarif_generated=true|false
# Writes to GITHUB_STEP_SUMMARY: markdown table of per-check pass/fail results.
#
# SARIF files are written to compliance-sarifs/ (cwd-relative) for subsequent
# upload by upload-sarifs.ps1. The directory is created if it does not exist.
#
# Parameters:
#   -RunnerExe    Path to the compiled ComplianceRunner executable.
#   -Checks       Space-separated check names (e.g. "CodeStandards NamingConventions").
#   -OrgUrl       Organisation URL passed to the runner (github.server_url/github.repository).
#   -FileListPath Path to the changed-files list (default: changed_files.txt).

param(
    [Parameter(Mandatory)][string]$RunnerExe,
    [Parameter(Mandatory)][string]$Checks,
    [Parameter(Mandatory)][string]$OrgUrl,
    [string]$FileListPath = "changed_files.txt"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fileList = @(Get-Content $FileListPath | ForEach-Object { $_ -replace '/', '\' })

# Always-visible diagnostics — these will appear in the step log unconditionally.
Write-Host "DIAG: Checks param length=$($Checks.Length) value='$Checks'"
Write-Host "DIAG: Checks UTF-8 bytes: $([System.Text.Encoding]::UTF8.GetBytes($Checks.PadRight(1)) | Select-Object -First 40 | ForEach-Object { "{0:X2}" -f $_ })"
Write-Host "DIAG: FileList count=$($fileList.Count)"

# Split on all Unicode whitespace/separator chars ([\s\p{Z}]+) via .NET regex so that
# non-ASCII spaces (e.g. U+00A0 non-breaking space) are also treated as delimiters.
$checks = @([regex]::Split($Checks.Trim(), '[\s\p{Z}]+') | Where-Object { $_ -ne '' })

Write-Host "::notice title=Compliance checks::Running ($($checks.Count)): $($checks -join ', ')"

if ($fileList.Count -eq 0) {
    Write-Host "::warning::changed_files.txt is empty — no files to check. Skipping compliance runner."
    "sarif_generated=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    exit 0
}

$anyFailure   = 0
$checkResults = [System.Collections.Generic.List[hashtable]]::new()

foreach ($check in $checks) {
    Write-Host "::group::BHoM $check compliance"
    & $RunnerExe $check --output github --org-url "$OrgUrl" @fileList
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { $anyFailure = 1 }
    Write-Host "::endgroup::"
    $checkResults.Add(@{ Check = $check; Ok = $ok })
}

$sarifDir = "compliance-sarifs"
New-Item -ItemType Directory -Force -Path $sarifDir | Out-Null
foreach ($check in $checks) {
    Write-Host "::group::SARIF export ($check)"
    & $RunnerExe $check --output sarif --sarif-file "$sarifDir\compliance-$check.sarif" --org-url "$OrgUrl" @fileList
    Write-Host "::endgroup::"
}

$sarifGenerated = (@(Get-ChildItem $sarifDir -Filter "*.sarif" -ErrorAction SilentlyContinue).Count -gt 0).ToString().ToLower()
"sarif_generated=$sarifGenerated" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

if ($env:GITHUB_STEP_SUMMARY) {
    $mdLines = @("### Compliance check results", "", "| Check | Result |", "|---|---|")
    foreach ($r in $checkResults) {
        $icon   = if ($r.Ok) { ":white_check_mark:" } else { ":x:" }
        $status = if ($r.Ok) { "Passed" } else { "**Failed**" }
        $mdLines += "| $($r.Check) | $icon $status |"
    }
    $mdLines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

if ($anyFailure -ne 0) {
    Write-Host "::error::One or more compliance checks failed."
    exit 1
}
