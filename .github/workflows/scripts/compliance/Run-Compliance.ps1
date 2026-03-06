param(
    [Parameter(Mandatory)][string]$Runner,
    [string]$ChangedFilesPath = "changed_files.txt",
    [string]$Checks           = "code copyright documentation"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Runner)) {
    Write-Host "Publish contents:"
    Get-ChildItem -Recurse (Split-Path $Runner) | Select-Object FullName
    Write-Error "Runner executable not found at: $Runner"
    exit 1
}

# @() forces a [string[]] even when only one file changed.
# Without it, a scalar string splats as a char[] and each character
# becomes a separate argument to the runner.
$fileList = @(Get-Content $ChangedFilesPath | ForEach-Object { $_ -replace '/', '\' })
$checks   = @($Checks -split '\s+' | Where-Object { $_ -ne '' })

Write-Host "::notice title=Compliance checks::Running: $($checks -join ', ')"

$anyFailure     = 0
$sarifGenerated = "false"
$checkResults   = [System.Collections.Generic.List[hashtable]]::new()

foreach ($check in $checks) {
    Write-Host "::group::BHoM $check compliance"
    & $Runner $check --output github @fileList
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { $anyFailure = 1 }
    Write-Host "::endgroup::"

    $checkResults.Add(@{ Check=$check; Ok=$ok })
}

# SARIF is only meaningful for the 'code' check (Roslyn diagnostics).
if ($checks -contains "code") {
    Write-Host "::group::SARIF export (code)"
    & $Runner code --output sarif --sarif-file compliance.sarif @fileList
    if ($LASTEXITCODE -eq 0) { $sarifGenerated = "true" }
    Write-Host "::endgroup::"
}

"sarif_generated=$sarifGenerated" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

# Step summary: per-check result table
if ($env:GITHUB_STEP_SUMMARY) {
    $mdLines = @("### Compliance check results", "",
                 "| Check | Result |",
                 "|---|---|")
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
