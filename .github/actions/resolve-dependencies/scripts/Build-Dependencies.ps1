param(
    [string]$Configuration = "Release",
    [string]$CloneRoot     = "C:\bhom-deps"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Uses dotnet build for SDK-style repos. Hard-fails on legacy (packages.config) repos.
function Invoke-BHoMBuild {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Config
    )

    $targetDir = if (Test-Path $Target -PathType Container) { $Target } else { Split-Path $Target }

    # Fail fast if packages.config is present — legacy NuGet/MSBuild is no longer supported.
    $legacyCount = (Get-ChildItem $targetDir -Recurse -Filter packages.config -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($legacyCount -gt 0) {
        throw "packages.config detected in $targetDir — legacy NuGet/MSBuild is not supported. Migrate all projects to SDK-style."
    }

    # Push into the repo directory for consistent relative path resolution.
    Push-Location $targetDir
    try {
        dotnet restore $Target
        if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed for $Target" }

        dotnet build $Target -c $Config --no-restore --nologo
        if ($LASTEXITCODE -ne 0) { throw "dotnet build failed for $Target" }
    }
    finally {
        Pop-Location
    }
}

$cloneRoot       = $CloneRoot
$depsDir         = "deps"
$orderOut        = Join-Path $depsDir "_order.txt"
$overallFailures = @()
$buildResults    = [System.Collections.Generic.List[hashtable]]::new()

if (-not (Test-Path $orderOut)) {
    Write-Warning "No build order file found at $orderOut."
    $order = @()
}
else {
    # Filter blank lines: _order.txt may be written empty when there are no dependencies.
    $order = @(Get-Content $orderOut | Where-Object { $_ -match '\S' })
}

if ($order.Count -eq 0) {
    Write-Host "::notice::No dependencies to build — skipping dependency build step."
    exit 0
}

foreach ($ownerRepo in $order) {

    $repoName = $ownerRepo.Split("/")[-1]
    $repoPath = Join-Path $cloneRoot $repoName
    if (-not (Test-Path $repoPath)) {
        # Hard-fail on missing clone: resolution recorded this repo but the clone failed
        # (auth/network error). Continuing would yield a confusing "assembly not found" later.
        Write-Host "::error title=Build::Clone not found at $repoPath — $ownerRepo was in the build order but was never cloned. Check for earlier auth or network errors in the dependency resolution step."
        $overallFailures += "$repoName"
        Write-Host "::endgroup::"
        continue
    }

    Write-Host "::group::Building $repoName"

    $solution  = Get-ChildItem $repoPath -Recurse -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
    $buildType = "dotnet build (SDK)"
    $buildOk   = $true

    try {

        if ($null -ne $solution) {
            Invoke-BHoMBuild -Target $solution.FullName -Config $Configuration
        }
        else {
            $projects = Get-ChildItem $repoPath -Recurse -Filter *.csproj -ErrorAction SilentlyContinue

            if ($projects.Count -eq 0) {
                Write-Host "No .sln or .csproj in $repoName — skipping."
                $buildType = "skipped"
            }
            else {
                foreach ($p in $projects) {
                    Invoke-BHoMBuild -Target $p.FullName -Config $Configuration
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

# Assemblies are staged to ProgramData\BHoM\Assemblies by each repo's PostBuildEvent.
# That directory is the canonical output cached by the calling action.
$bhomAssemblies = Join-Path $env:ProgramData "BHoM\Assemblies"
$totalAssemblies = @(Get-ChildItem $bhomAssemblies -Filter *.dll -ErrorAction SilentlyContinue).Count
Write-Host "Total assemblies in ${bhomAssemblies}: $totalAssemblies"

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
