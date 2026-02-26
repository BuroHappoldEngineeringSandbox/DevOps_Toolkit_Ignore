# Build-Dependencies.ps1
# Purpose: Restore & build each dependency solution.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$config = if ($env:CONFIG) { $env:CONFIG } else { 'Release' }

# If deps folder doesn't exist (e.g., no dependencies), exit cleanly
if (-not (Test-Path "deps")) {
    Write-Host "No 'deps' folder found. Nothing to build."
    exit 0
}

$repos = Get-ChildItem -Path "deps" -Directory -ErrorAction SilentlyContinue
if (-not $repos -or $repos.Count -eq 0) {
    Write-Host "No cloned repositories under 'deps'. Nothing to build."
    exit 0
}

foreach ($repoDir in $repos) {
    $sln = Get-ChildItem $repoDir.FullName -Recurse -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sln) {
        Write-Warning "No .sln found in '$($repoDir.FullName)'. Skipping."
        continue
    }

    $name = Split-Path -Leaf $repoDir.FullName
    Write-Host "::group::Restore & Build $name"
    dotnet restore $sln.FullName
    dotnet build $sln.FullName --configuration $config
    Write-Host "::endgroup::"
}