param(
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$depsDir  = "deps"
$orderOut = Join-Path $depsDir "_order.txt"
$overallFailures = @()

if (-not (Test-Path $orderOut)) {
    Write-Warning "No build order file found; falling back to directory enumeration."
    $order = (Get-ChildItem $depsDir -Directory | Select-Object -ExpandProperty Name)
}
else {
    $order = Get-Content $orderOut
}

foreach ($repoName in $order) {

    $repoPath = Join-Path $depsDir $repoName
    if (-not (Test-Path $repoPath)) { continue }

    Write-Host "::group::Building $repoName::"

    $solution = Get-ChildItem $repoPath -Recurse -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
    $usesPackagesConfig = (Get-ChildItem $repoPath -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0

    try {

        if ($null -ne $solution) {

            if ($usesPackagesConfig) {
                nuget restore $solution.FullName -NonInteractive
            }
            else {
                dotnet restore $solution.FullName
            }

            dotnet build $solution.FullName -c $Configuration --no-restore --nologo -m
        }
        else {

            $projects = Get-ChildItem $repoPath -Recurse -Filter *.csproj -ErrorAction SilentlyContinue

            if ($projects.Count -eq 0) {
                Write-Host "No .sln or .csproj in $repoName — skipping."
            }
            else {

                foreach ($p in $projects) {

                    if ($usesPackagesConfig) {
                        nuget restore $repoPath -NonInteractive
                    }
                    else {
                        dotnet restore $p.FullName
                    }

                    dotnet build $p.FullName -c $Configuration --no-restore --nologo -m
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
    Where-Object { $_.FullName -match "\\bin\\$Configuration\\" } |
    ForEach-Object { Copy-Item $_.FullName "deps-assemblies" -Force }

Write-Host "Collected assemblies (sample):"
Get-ChildItem "deps-assemblies" -Filter *.dll -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -First 60 |
    ForEach-Object { $_.Name }

# To enforce CI failure on dependency build errors, uncomment:
# if ($overallFailures.Count -gt 0) {
#     Write-Error ("One or more dependency builds failed:`n - " + ($overallFailures -join "`n - "))
# }