# build-alt-configs.ps1 — builds MSBuild configurations listed in altConfigs.txt.
# Expects: cwd = caller repo root, nuget and msbuild on PATH (windows-latest runner).
#
# altConfigs.txt format: org/repo/ConfigName (one entry per line).
# Only ConfigName (the third segment) is used — org/repo are legacy metadata from the
# BHoMBot dependency graph. Blank lines and # comments are skipped.
#
# ZeroCodeTool requires a config-specific MSBuild restore to avoid errorreport flag
# noise on stdout (issue #218 in BHoMBot). All other configs share a single NuGet
# restore run before the loop (packages.config is configuration-agnostic).
#
# Parameters:
#   -SlnPath   Path to the primary solution file.

param(
    [Parameter(Mandatory)][string]$SlnPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path "altConfigs.txt")) {
    Write-Host "::notice::No altConfigs.txt found — skipping alt configuration builds."
    exit 0
}

$configs = Get-Content altConfigs.txt |
           ForEach-Object { $_.Trim() } |
           Where-Object   { $_ -ne "" -and -not $_.StartsWith("#") }

# packages.config is configuration-agnostic: a single NuGet restore covers every
# non-ZeroCodeTool alt config, avoiding N redundant restores in the loop.
Write-Host "::group::NuGet restore (alt configurations)"
nuget restore $SlnPath -NonInteractive
$restoreExit = $LASTEXITCODE
Write-Host "::endgroup::"
if ($restoreExit -ne 0) {
    Write-Host "::error title=Build::NuGet restore failed before alt config builds."
    exit $restoreExit
}

$anyFailure = $false

foreach ($line in $configs) {
    $parts = $line.Split('/')
    if ($parts.Length -lt 3) {
        Write-Host "::warning::Skipping malformed altConfigs entry: '$line' (expected org/repo/ConfigName)"
        continue
    }

    $configName = $parts[2]
    Write-Host "::group::Alt config: $configName"

    if ($configName -eq "ZeroCodeTool") {
        # Config-specific MSBuild restore required for ZeroCodeTool — using nuget restore
        # would surface errorreport flags as false-positive error lines (issue #218).
        msbuild $SlnPath /t:Restore /p:Configuration=$configName /verbosity:minimal /nologo
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error title=Build::MSBuild restore failed for ZeroCodeTool."
            $anyFailure = $true
            Write-Host "::endgroup::"
            continue
        }
    }

    msbuild $SlnPath /m /p:Configuration=$configName /p:Platform="Any CPU" /verbosity:minimal /nologo

    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error title=Build::Alt config '$configName' failed."
        $anyFailure = $true
    } else {
        Write-Host "::notice title=Build::Alt config '$configName' succeeded."
    }

    Write-Host "::endgroup::"
}

if ($anyFailure) { exit 1 }
