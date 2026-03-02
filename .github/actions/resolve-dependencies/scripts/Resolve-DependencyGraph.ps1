param(
    [string]$DepsFile   = "dependencies.txt",
    [string]$ExtraRepos = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root       = (Get-Location).Path
$depsDir    = Join-Path $root "deps"
$shaFile    = Join-Path $depsDir "_shas.txt"
$orderOut   = Join-Path $depsDir "_order.txt"
$selectFile = Join-Path $depsDir "_selection.txt"

if (Test-Path $selectFile) { Remove-Item $selectFile -Force }

function Lines([string]$path) {
    if (Test-Path $path) {
        return Get-Content $path |
            Where-Object { $_ -and -not $_.Trim().StartsWith("#") } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    }
    return @()
}

function Parse-RepoSpec([string]$spec) {
    $ref = $null
    if ($spec.Contains("@")) {
        $parts = $spec.Split("@", 2)
        $spec  = $parts[0].Trim()
        $ref   = $parts[1].Trim()
    }
    return @{ Key = $spec; Ref = $ref }
}

# Determine prefer/fallback logic
$Prefer   = $env:PR_BRANCH
if (-not $Prefer -or $Prefer -eq "") { $Prefer = "feature/unknown" }

$Fallback = $env:BASE_BRANCH
if (-not $Fallback -or $Fallback -eq "") { $Fallback = "main" }

# Track clones
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}
$pathMap = @{}

function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $parts = $ownerRepo.Split("/")
    if ($parts.Count -ne 2) { return $null }

    $name = $parts[1]
    $path = Join-Path $depsDir $name

    if (-not (Test-Path (Join-Path $path ".git"))) {

        $url = "https://x-access-token:$env:DEP_TOKEN@github.com/$ownerRepo.git"
        git clone $url $path --no-tags --depth 1 | Out-Null

        Push-Location $path
        $selectedRef = $null
        $used = $false

        if ($ref) {
            $hasHead = git ls-remote --heads origin $ref
            $hasTag  = git ls-remote --tags  origin $ref
            if ($hasHead -or $hasTag) {
                git fetch origin $ref --depth 1 | Out-Null
                git checkout -q $ref
                $selectedRef = $ref
                $used = $true
            }
            else {
                Write-Warning "Explicit ref '$ref' not found on '$ownerRepo' — falling back."
            }
        }

        if (-not $used) {
            $hasPrefer = git ls-remote --heads origin $Prefer
            if ($hasPrefer) {
                git fetch origin $Prefer --depth 1 | Out-Null
                git checkout -q $Prefer
                $selectedRef = $Prefer
            }
            else {
                git fetch origin $Fallback --depth 1 | Out-Null
                git checkout -q $Fallback
                $selectedRef = $Fallback
            }
        }

        $sha = (git rev-parse HEAD).Trim()
        Add-Content -Path $shaFile -Value "$ownerRepo $sha"
        Add-Content -Path $selectFile -Value "$ownerRepo|$name|$selectedRef|$sha"

        git remote set-url origin "https://github.com/$ownerRepo.git" | Out-Null

        Pop-Location
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path

    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

function Build-Chain([string]$ownerRepo, [bool]$includeSelf=$false, [string]$ref=$null) {

    $chain = New-Object System.Collections.Generic.List[string]

    if (-not $cloned.Contains($ownerRepo)) {
        $cloned.Add($ownerRepo) | Out-Null
        Clone-And-Checkout $ownerRepo $ref
    }

    $repoPath = $pathMap[$ownerRepo]
    $depsFileLocal = Join-Path $repoPath "dependencies.txt"

    if (Test-Path $depsFileLocal) {
        foreach ($line in (Lines $depsFileLocal)) {
            $parsed = Parse-RepoSpec $line
            $childList = Build-Chain $parsed.Key $true $parsed.Ref
            foreach ($c in $childList) { $chain.Add($c) | Out-Null }
        }
    }

    if ($includeSelf) { $chain.Add($ownerRepo) | Out-Null }

    return ,$chain
}

# ------------------- PHASE A -------------------
Write-Host "----- PHASE A: Caller dependencies from $DepsFile -----"
$phaseA = New-Object System.Collections.Generic.List[string]
foreach ($seed in (Lines $DepsFile)) {
    $parsed = Parse-RepoSpec $seed
    $chain = Build-Chain $parsed.Key $true $parsed.Ref
    foreach ($item in $chain) {
        if (-not $phaseA.Contains($item)) { $phaseA.Add($item) | Out-Null }
    }
}
if ($phaseA.Count -eq 0) { Write-Host "(none)" } else { $phaseA | ForEach-Object { Write-Host "A: $_" } }

# ------------------- PHASE B -------------------
Write-Host "----- PHASE B: Extra repos + their own dependencies -----"
$phaseB = New-Object System.Collections.Generic.List[string]

if ($ExtraRepos) {
    $seeds = $ExtraRepos.Split("`n") | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }

    foreach ($seed in $seeds) {
        $parsed = Parse-RepoSpec $seed
        $chain = Build-Chain $parsed.Key $true $parsed.Ref
        foreach ($item in $chain) {
            if (-not $phaseB.Contains($item)) { $phaseB.Add($item) | Out-Null }
        }
        Write-Host "B (seed): $($parsed.Key)"
    }
}
else {
    Write-Host "(none)"
}

# ------------------- MERGE -------------------
$seen   = New-Object System.Collections.Generic.HashSet[string]
$merged = New-Object System.Collections.Generic.List[string]

foreach ($k in ($phaseA + $phaseB)) {
    if (-not $seen.Contains($k)) {
        $seen.Add($k)     | Out-Null
        $merged.Add($k)   | Out-Null
    }
}

$folderOrder = $merged | ForEach-Object {
    if ($nameMap.ContainsKey($_)) { $nameMap[$_] }
    else { ($_ -split "/")[1] }
}

$folderOrder | Set-Content -Path $orderOut -Encoding utf8

Write-Host "== Final build order =="
Get-Content $orderOut | ForEach-Object { Write-Host " - $_" }

# ------------------- SELECTION SUMMARY -------------------
if (Test-Path $selectFile) {
    Write-Host "== Checkout selections =="
    foreach ($line in (Get-Content $selectFile)) {
        $t = $line.Split("|")
        $repo   = $t[0]
        $folder = $t[1]
        $sel    = $t[2]
        $sha    = $t[3]
        Write-Host " - $repo (folder: $folder) -> $sel @ $sha"
    }
}