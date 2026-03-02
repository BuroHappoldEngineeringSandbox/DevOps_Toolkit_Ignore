Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$depsDir  = "deps"
$orderOut = Join-Path $depsDir "_order.txt"
$overallFailures = @()

if (-not (Test-Path $orderOut)) {
    Write-Warning "No build order file found; falling back to directory enumeration."
    $order = (Get-ChildItem $depsDir -Directory | Select-Object -ExpandProperty Name)
} else {
    $order = Get-Content $orderOut
}

foreach ($repoName in $order) {
    $repoPath = Join-Path $depsDir $repoName
    if (-not (Test-Path $repoPath)) { continue }

    Write-Host "::group::Building $repoName"

    $solution = Get-ChildItem $repoPath -Recurse -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
    $usesPackagesConfig = (Get-ChildItem $repoPath -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0

    try {
        if ($null -ne $solution) {
            if ($usesPackagesConfig) {
                # Legacy restore to solution-local 'packages/' folder (v2 layout)
                nuget restore $solution.FullName -NonInteractive
            } else {
                dotnet restore $solution.FullName
            }
            dotnet build $solution.FullName -c $env:CONFIGURATION --no-restore --nologo -m
        }
        else {
            $projects = Get-ChildItem $repoPath -Recurse -Filter *.csproj -ErrorAction SilentlyContinue
            if ($projects.Count -eq 0) {
                Write-Host "No .sln or .csproj in $repoName — skipping build."
            } else {
                foreach ($p in $projects) {
                    if ($usesPackagesConfig) {
                        # When only projects are present, restore at repo root
                        nuget restore $repoPath -NonInteractive
                    } else {
                        dotnet restore $p.FullName
                    }
                    dotnet build $p.FullName -c $env:CONFIGURATION --no-restore --nologo -m
                }
            }
        }
    }
    catch {
        Write-Warning "Build FAILED for '$repoName': $($_.Exception.Message)"
        $overallFailures += "$repoName"
    }

    Write-Host "::endgroup::"
}

if (-not (Test-Path "deps-assemblies")) {
    New-Item -ItemType Directory -Force -Path "deps-assemblies" | Out-Null
}

Get-ChildItem "deps" -Recurse -Filter *.dll -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match "\\bin\\$($env:CONFIGURATION)\\" } |
  ForEach-Object { Copy-Item $_.FullName "deps-assemblies" -Force }

Write-Host "Collected assemblies (sample):"
Get-ChildItem "deps-assemblies" -Filter *.dll -ErrorAction SilentlyContinue |
  Sort-Object Name |
  Select-Object -First 60 |
  ForEach-Object { $_.Name }

# Optional failure: keep original behavior (do not fail job).
# If you want to fail when any build fails, uncomment:
# if ($overallFailures.Count -gt 0) {
#   Write-Error ("One or more dependency builds failed:`n - " + ($overallFailures -join "`n - "))
# }