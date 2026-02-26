# Collect-Assemblies.ps1
# Purpose: Copy dependency-produced *.dll from bin/Release|Debug to a single folder (deps-assemblies).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$out = "deps-assemblies"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# If there are no dependencies or no builds produced output, this will just copy zero files.
if (Test-Path "deps") {
    Get-ChildItem -Path "deps" -Recurse -Include *.dll -ErrorAction SilentlyContinue `
      | Where-Object { $_.FullName -match "\\bin\\(Release|Debug)\\" } `
      | Copy-Item -Destination $out -Force -ErrorAction SilentlyContinue
}

$count = (Get-ChildItem $out -Filter *.dll -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "Collected $count assemblies in '$out'."