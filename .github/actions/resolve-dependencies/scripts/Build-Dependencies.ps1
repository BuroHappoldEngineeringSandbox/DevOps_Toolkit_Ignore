param(
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Runs the appropriate build tool for a given target path.
# Uses MSBuild for legacy projects (packages.config detected),
# dotnet build for SDK-style projects.
# ------------------------------------------------------------
function Invoke-BHoMBuild {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][bool]  $IsLegacy,
        [Parameter(Mandatory)][string]$Config
    )

    # Push into the repo directory before invoking dotnet/msbuild.
    # Keeps relative path resolution consistent for both SDK and legacy tools.
    $targetDir = if (Test-Path $Target -PathType Container) { $Target } else { Split-Path $Target }
    Push-Location $targetDir
    try {
        if ($IsLegacy) {
            Write-Host "Detected legacy project (packages.config) — using NuGet restore + MSBuild"
            nuget restore $Target -NonInteractive
            if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed for $Target" }

            msbuild $Target `
                /m /p:Configuration=$Config `
                /p:Platform="Any CPU" `
                /verbosity:minimal /nologo
            if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for $Target" }
        }
        else {
            dotnet restore $Target
            if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed for $Target" }

            dotnet build $Target -c $Config --no-restore --nologo -m
            if ($LASTEXITCODE -ne 0) { throw "dotnet build failed for $Target" }
        }
    }
    finally {
        Pop-Location
    }
}

# ------------------------------------------------------------

$cloneRoot       = "C:\bhom-deps"
$depsDir         = "deps"
$orderOut        = Join-Path $depsDir "_order.txt"
$overallFailures = @()
$buildResults    = [System.Collections.Generic.List[hashtable]]::new()

if (-not (Test-Path $orderOut)) {
    Write-Warning "No build order file found at $orderOut."
    $order = @()
}
else {
    # _order.txt contains owner/repo lines; derive repo name and path from each.
    $order = Get-Content $orderOut
}

foreach ($ownerRepo in $order) {

    $repoName = $ownerRepo.Split("/")[-1]
    $repoPath = Join-Path $cloneRoot $repoName
    if (-not (Test-Path $repoPath)) {
        Write-Host "::warning::Clone not found at $repoPath — skipping $ownerRepo"
        continue
    }

    Write-Host "::group::Building $repoName"

    $solution           = Get-ChildItem $repoPath -Recurse -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
    $usesPackagesConfig = (Get-ChildItem $repoPath -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
    $buildType          = if ($usesPackagesConfig) { "MSBuild (legacy)" } else { "dotnet build (SDK)" }
    $buildOk            = $true

    # Migration tracking: detect repos that are partially through legacy → SDK migration.
    # A repo with packages.config alongside SDK-style .csproj files is using MSBuild for
    # everything (conservative and correct), but should be flagged so the migration effort
    # can track remaining work. Once all packages.config files are removed the repo flips
    # automatically to the dotnet build path on the next run.
    if ($usesPackagesConfig) {
        $sdkProjectCount = (Get-ChildItem $repoPath -Recurse -Filter *.csproj -ErrorAction SilentlyContinue |
            Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match '<Project\s+Sdk=' } |
            Measure-Object).Count
        if ($sdkProjectCount -gt 0) {
            Write-Host "::notice title=Migration::$repoName is partially migrated — $sdkProjectCount SDK-style project(s) detected alongside packages.config. Building via MSBuild (safe for both). Remove all packages.config files to complete the migration to dotnet build."
        }
    }

    try {

        if ($null -ne $solution) {
            Invoke-BHoMBuild -Target $solution.FullName -IsLegacy $usesPackagesConfig -Config $Configuration
        }
        else {
            $projects = Get-ChildItem $repoPath -Recurse -Filter *.csproj -ErrorAction SilentlyContinue

            if ($projects.Count -eq 0) {
                Write-Host "No .sln or .csproj in $repoName — skipping."
                $buildType = "skipped"
            }
            else {
                foreach ($p in $projects) {
                    Invoke-BHoMBuild -Target $p.FullName -IsLegacy $usesPackagesConfig -Config $Configuration
                }
            }
        }

        Write-Host "::notice title=Build OK::$repoName built successfully ($buildType)"
    }
    catch {
        $buildOk = $false
        Write-Warning "Build FAILED for '$repoName': $($_.Exception.Message)"
        Write-Host "::error title=Build FAILED::$repoName — $($_.Exception.Message)"
        $overallFailures += "$repoName"
    }

    $buildResults.Add(@{ Repo=$repoName; Type=$buildType; Ok=$buildOk })

    Write-Host "::endgroup::"
}

# Assemblies are staged to C:\ProgramData\BHoM\Assemblies by each repo's
# own PostBuildEvent (xcopy). No collection step needed — that directory
# is the canonical output and is cached directly by the action.
$bhomAssemblies = Join-Path $env:ProgramData "BHoM\Assemblies"
$totalAssemblies = @(Get-ChildItem $bhomAssemblies -Filter *.dll -ErrorAction SilentlyContinue).Count
Write-Host "Total assemblies in $bhomAssemblies: $totalAssemblies"

# ------------------------------------------------------------
# Step summary: dependency build results table
# ------------------------------------------------------------
if ($env:GITHUB_STEP_SUMMARY) {
    $mdLines = @("### Dependency build results", "",
                 "| Repository | Build tool | Result |",
                 "|---|---|---|")

    foreach ($r in $buildResults) {
        $icon   = if ($r.Ok) { ":white_check_mark:" } else { ":x:" }
        $status = if ($r.Ok) { "Success" } else { "**FAILED**" }
        $mdLines += "| ``$($r.Repo)`` | $($r.Type) | $icon $status |"
    }

    $mdLines += ""
    $mdLines += "_Total assemblies in ProgramData\\BHoM\\Assemblies: **$totalAssemblies**_"

    $mdLines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

if ($overallFailures.Count -gt 0) {
    Write-Error ("One or more dependency builds failed:`n - " + ($overallFailures -join "`n - "))
}
