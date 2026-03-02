
<#
.SYNOPSIS
    Resolve and clone all dependency repositories using a two‑phase
    recursive model, producing build order, SHAs, and selection metadata.

.DESCRIPTION
    This script:
      - Reads the caller repo's dependencies.txt (Phase A)
      - Reads extra Phase B seeds (optional)
      - Performs depth-first dependency expansion
      - Clones each repo only once
      - Selects branch/tag/SHA based on:
            1. explicit @ref
            2. PR branch
            3. base branch
            4. fallback to 'main'
      - Records SHAs (used for cache key)
      - Produces:
            deps/_order.txt
            deps/_shas.txt
            deps/_selection.txt

.OUTPUTS
    deps/_order.txt     - build folder order
    deps/_shas.txt      - repo SHAs for caching
    deps/_selection.txt - summary of checkout branch + SHA

.NOTES
    The two-phase model allows a repo (e.g. Adapter) to declare
    dependencies AND also include extra repos whose dependencies
    must be resolved afterwards.
#>

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

# Parse dependency lines, ignoring empty lines and comments; also validate format
function Lines([string]$path) {
    if (Test-Path $path) {
        return Get-Content $path |
            Where-Object { $_ -and -not $_.Trim().StartsWith("#") } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and $_ -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9._/-]+)?$" }
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

# Branch selection logic
$Prefer   = $env:PR_BRANCH
if (-not $Prefer -or $Prefer -eq "") { $Prefer = "feature/unknown" }

$Fallback = $env:BASE_BRANCH
if (-not $Fallback -or $Fallback -eq "") { $Fallback = "main" }

# Track cloned repos to avoid redundant work; also maintain maps for folder naming and later summary output
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}
$pathMap = @{}

# Safely extract folder name from owner/repo, with fallback to 'unknown' for unexpected formats
function Get-FolderName([string]$ownerRepo) {
    $parts = $ownerRepo.Split("/")
    if ($parts.Length -ge 2) { return $parts[1] }
    if ($parts.Length -eq 1 -and $parts[0] -ne "") { return $parts[0] }
    return "unknown"
}

# Clone the repo if not already cloned, then checkout the appropriate ref based on explicit input or branch availability
function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $name = Get-FolderName $ownerRepo
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

        # Record the selected SHA for caching and summary output
        $sha = (git rev-parse HEAD).Trim()
        Add-Content -Path $shaFile -Value "$ownerRepo $sha"
        Add-Content -Path $selectFile -Value "$ownerRepo|$name|$selectedRef|$sha"

        # Reset origin to use token-free URL for later operations
        git remote set-url origin "https://github.com/$ownerRepo.git" | Out-Null

        Pop-Location
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path

    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

# Depth-first recursion: resolve children before parent
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

# ---------------- PHASE A ----------------
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

# ---------------- PHASE B ----------------
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

# ---------------- MERGE ----------------
$seen   = New-Object System.Collections.Generic.HashSet[string]
$merged = New-Object System.Collections.Generic.List[string]

foreach ($k in ($phaseA + $phaseB)) {
    if (-not $seen.Contains($k)) {
        $seen.Add($k)   | Out-Null
        $merged.Add($k) | Out-Null
    }
}

# Safe folder name mapping (handles unexpected input formats)
$folderOrder = $merged | ForEach-Object {

    if ($nameMap.ContainsKey($_)) {
        $nameMap[$_]
    }
    else {
        $parts = $_.Split("/")
        if ($parts.Length -ge 2) { $parts[1] }
        elseif ($parts.Length -eq 1) { $parts[0] }
        else { "unknown" }
    }
}

$folderOrder | Set-Content -Path $orderOut -Encoding utf8

Write-Host "== Final build order =="
Get-Content $orderOut | ForEach-Object { Write-Host " - $_" }

# ---------------- SELECTION SUMMARY ----------------
if (Test-Path $selectFile) {
    Write-Host "== Checkout selections =="
    foreach ($line in (Get-Content $selectFile)) {
        $t = $line.Split("|")
        if ($t.Length -ge 4) {
            $repo   = $t[0]
            $folder = $t[1]
            $sel    = $t[2]
            $sha    = $t[3]
            Write-Host " - $repo (folder: $folder) -> $sel @ $sha"
        }
    }
}