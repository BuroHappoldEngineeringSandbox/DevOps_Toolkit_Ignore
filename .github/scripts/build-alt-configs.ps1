# build-alt-configs.ps1 — builds SDK-style configurations listed in altConfigs.txt.
# Expects: cwd = caller repo root, dotnet SDK on PATH (windows-latest runner).
#
# altConfigs.txt format: org/repo/ConfigName (one entry per line).
# Only ConfigName (the third segment) is used — org/repo are legacy metadata from the
# BHoMBot dependency graph. Blank lines and # comments are skipped.
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

# Fail fast if any packages.config is present — legacy NuGet/MSBuild is no longer supported.
$legacyCount = (Get-ChildItem . -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Measure-Object).Count
if ($legacyCount -gt 0) {
    Write-Host "::error title=Build::packages.config detected — legacy NuGet/MSBuild is not supported. Migrate all projects to SDK-style before using alt configuration builds."
    exit 1
}

$configs = Get-Content altConfigs.txt |
           ForEach-Object { $_.Trim() } |
           Where-Object   { $_ -ne "" -and -not $_.StartsWith("#") }

$anyFailure = $false

foreach ($line in $configs) {
    $parts = $line.Split('/')
    if ($parts.Length -lt 3) {
        Write-Host "::warning::Skipping malformed altConfigs entry: '$line' (expected org/repo/ConfigName)"
        continue
    }

    $configName = $parts[2]
    Write-Host "::group::Alt config: $configName"

    dotnet build $SlnPath -c $configName --nologo
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error title=Build::Alt config '$configName' failed."
        $anyFailure = $true
    } else {
        Write-Host "::notice title=Build::Alt config '$configName' succeeded."
    }

    Write-Host "::endgroup::"
}

if ($anyFailure) { exit 1 }
