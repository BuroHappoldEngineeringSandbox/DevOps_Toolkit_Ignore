param(
    [string]$DepsFile   = "dependencies.txt",
    [string]$ExtraRepos = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root        = (Get-Location).Path
$depsDir     = Join-Path $root 'deps'
$shaFile     = Join-Path $depsDir '_shas.txt'
$orderOut    = Join-Path $depsDir '_order.txt'
$selectFile  = Join-Path $depsDir '_selection.txt'

if (Test-Path $selectFile) { Remove-Item $selectFile -Force }

function Lines([string]$path) {
    if (Test-Path $path) {
        return Get-Content $path |
            Where-Object { $_ -and -not $_.Trim().StartsWith('#') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
    }
    @()
}

function Parse-RepoSpec([string]$spec) {
    $ref = $null
    if ($spec.Contains('@')) {
        $parts = $spec.Split('@',2)
        $spec  = $parts[0].Trim()
        $ref   = $parts[1].Trim()
    }
    return @{ Key = $spec; Ref = $ref }  # owner/repo, ref
}

# Match your original prefer/fallback logic:
$Prefer   = $env:PR_BRANCH;  if (-not $Prefer)   { $Prefer = 'feature/unknown' }
$Fallback = $env:BASE_BRANCH; if (-not $Fallback) { $Fallback = 'main' }

# Global de-dup of clones (owner/repo)
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{} # owner/repo -> folder name
$pathMap = @{} # owner/repo -> full path

function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $parts = $ownerRepo.Split('/')
    if ($parts.Count -ne 2) { return $null }
    $name = $parts[1]
    $path = Join-Path $depsDir $name

    if (-not (Test-Path (Join-Path $path '.git'))) {

        $url = "https://x-access-token:$env:DEP_TOKEN@github.com/$ownerRepo.git"
        git clone $url $path --no-tags --depth 1 | Out-Null

        Push-Location $path
        $used = $false
        $selectedRef = $null

        if ($ref) {
            $hasHead = git ls-remote --heads origin $ref
            $hasTag  = git ls-remote --tags  origin $ref
            if ($hasHead -or $hasTag) {
                git fetch origin $ref --depth 1 | Out-Null
                git checkout -q $ref
                Write-Host "Checked out '$name' at explicit ref '$ref'"
                $selectedRef = $ref
                $used = $true
            } else {
                Write-Warning "Explicit ref '$ref' not found on '$ownerRepo' — falling back."
            }
        }

        if (-not $used) {
            $hasPrefer = git ls-remote --heads origin $Prefer
            if ($hasPrefer) {
                git fetch origin $Prefer --depth 1 | Out-Null
                git checkout -q $Prefer
                Write-Host "Checked out '$name' on '$Prefer'"
                $selectedRef = $Prefer
            } else {
                git fetch origin $Fallback --depth 1 | Out-Null
                git checkout -q $Fallback
                Write-Host "Branch '$Prefer' not found on '$name' — fell back to '$Fallback'"
                $selectedRef = $Fallback
            }
        }

        $sha = (git rev-parse HEAD).Trim()
        # Record SHA as owner/repo SHA (unambiguous for cache keys)
        Add-Content -Path $shaFile -Value "$ownerRepo $sha"
        # NEW: record selection summary
        Add-Content -Path $selectFile -Value "$ownerRepo|$name|$selectedRef|$sha"

        # Optional safety: drop token from local remote URL
        git remote set-url origin "https://github.com/$ownerRepo.git" | Out-Null

        Pop-Location
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path
    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

# Walk a repo's deps_file in listed order (depth-first)
function Build-Chain([string]$ownerRepo, [bool]$includeSelf = $false, [string]$ref = $null) {

    $chain = New-Object System.Collections.Generic.List[string]

    if (-not $cloned.Contains($ownerRepo)) {
        $cloned.Add($ownerRepo) | Out-Null
        $repo = Clone-And-Checkout $ownerRepo $ref
    } else {
        $parts = $ownerRepo.Split('/')
        if (-not $nameMap.ContainsKey($ownerRepo)) { $nameMap[$ownerRepo] = $parts[1] }
        if (-not $pathMap.ContainsKey($ownerRepo)) { $pathMap[$ownerRepo] = Join-Path $depsDir $parts[1] }
    }

    $repoPath = $pathMap[$ownerRepo]
    $depsFile = Join-Path $repoPath 'dependencies.txt'
    if (Test-Path $depsFile) {
        foreach ($line in (Lines $depsFile)) {
            $p = Parse-RepoSpec $line
            # Recurse first (ensures child's deps before the child)
            $childList = Build-Chain $p.Key $true $p.Ref
            foreach ($c in $childList) { $chain.Add($c) | Out-Null }
        }
    }

    if ($includeSelf) { $chain.Add($ownerRepo) | Out-Null }
    return ,$chain
}

# ----------------- Phase A -----------------
Write-Host "----- PHASE A: Caller dependencies from $DepsFile -----"
$phaseA = New-Object System.Collections.Generic.List[string]
$seedsA = Lines $DepsFile
foreach ($seed in $seedsA) {
    $sp = Parse-RepoSpec $seed
    $chain = Build-Chain $sp.Key $true $sp.Ref
    foreach ($item in $chain) {
        if (-not $phaseA.Contains($item)) { $phaseA.Add($item) | Out-Null }
    }
}
if ($phaseA.Count -eq 0) { Write-Host "(none)" } else { $phaseA | ForEach-Object { Write-Host "A: $_" } }

# ----------------- Phase B -----------------
Write-Host "----- PHASE B: Extra repos + their own dependencies -----"
$phaseB = New-Object System.Collections.Generic.List[string]
if ($ExtraRepos) {
    $seedsB = @($ExtraRepos.Split("`n")) |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }
    foreach ($seed in $seedsB) {
        $sp = Parse-RepoSpec $seed
        $chain = Build-Chain $sp.Key $true $sp.Ref
        foreach ($item in $chain) {
            if (-not $phaseB.Contains($item)) { $phaseB.Add($item) | Out-Null }
        }
        Write-Host "B (seed): $($sp.Key)"
    }
} else {
    Write-Host "(none)"
}

# --------------- Merge orders ---------------
$seen  = New-Object System.Collections.Generic.HashSet[string]
$merged= New-Object System.Collections.Generic.List[string]
foreach ($k in $phaseA + $phaseB) {
    if (-not $seen.Contains($k)) { $seen.Add($k) | Out-Null; $merged.Add($k) | Out-Null }
}

# Map owner/repo -> folder name for build step output and save
$folderOrder = $merged | ForEach-Object {
    if ($nameMap.ContainsKey($_)) { $nameMap[$_] } else { ($_ -split '/')[1] }
}
$folderOrder | Set-Content -Path $orderOut -Encoding utf8

Write-Host "== Final build order (Phase A then Phase B, de-duped) =="
Get-Content $orderOut | ForEach-Object { Write-Host " - $_" }

# NEW: print the checkout selections summary
if (Test-Path $selectFile) {
    Write-Host "== Checkout selections =="
    Get-Content $selectFile | ForEach-Object {
        $t = $_.Split('|')
