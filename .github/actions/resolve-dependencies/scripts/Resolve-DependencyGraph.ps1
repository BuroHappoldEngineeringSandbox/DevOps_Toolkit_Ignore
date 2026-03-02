param(
    [string]$DepsFile   = "dependencies.txt",
    [string]$Mode       = "caller",   # "caller" | "seeds"
    [string]$Seeds      = ""          # used only when Mode = "seeds"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root       = (Get-Location).Path
$depsDir    = Join-Path $root "deps"
$shaFile    = Join-Path $depsDir "_shas.txt"
$orderOut   = Join-Path $depsDir "_order.txt"
$selectFile = Join-Path $depsDir "_selection.txt"

if (Test-Path $selectFile) { Remove-Item $selectFile -Force }

# ------------------------------------------------------------
# Read dependency lines, ignoring comments/blank lines, and
# strictly enforce "one repo per line" with no whitespace.
# Valid forms:
#   owner/repo
#   owner/repo@branch|tag|sha
# ------------------------------------------------------------
function Lines([string]$path) {
    if (Test-Path $path) {
        return Get-Content $path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and -not $_.StartsWith("#") } |
            ForEach-Object {
                if ($_.IndexOfAny(@(' ', "`t")) -ge 0) {
                    throw "Malformed dependency entry (contains whitespace): '$_'. Each line must be a single 'owner/repo' or 'owner/repo@ref'."
                }
                $_
            } |
            Where-Object { $_ -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9._/-]+)?$" }
    }
    return @()
}

# ------------------------------------------------------------
# Parse "owner/repo" and optional "@ref"
# ------------------------------------------------------------
function Parse-RepoSpec([string]$spec) {
    $ref = $null
    if ($spec.Contains("@")) {
        $parts = $spec.Split("@",2)
        $spec  = $parts[0].Trim()
        $ref   = $parts[1].Trim()
    }
    return @{ Key=$spec; Ref=$ref }
}

# ------------------------------------------------------------
# Branch preferences for dependency checkout:
#   1) explicit @ref (branch/tag/sha)
#   2) PR_BRANCH (if exists on dep)
#   3) BASE_BRANCH (if provided)
#   4) "main" (fallback)
# ------------------------------------------------------------
$Prefer   = $env:PR_BRANCH
if ([string]::IsNullOrWhiteSpace($Prefer)) { $Prefer = "feature/unknown" }

$Fallback = $env:BASE_BRANCH
if ([string]::IsNullOrWhiteSpace($Fallback)) { $Fallback = "main" }

# ------------------------------------------------------------
# Global tracking of clones and mappings
# ------------------------------------------------------------
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}  # owner/repo -> folder name
$pathMap = @{}  # owner/repo -> full path

function Get-FolderName([string]$ownerRepo) {
    $parts = $ownerRepo.Split("/")
    if ($parts.Length -ge 2) { return $parts[1] }
    if ($parts.Length -eq 1 -and $parts[0] -ne "") { return $parts[0] }
    return "unknown"
}

# ------------------------------------------------------------
# Clone repo + checkout appropriate ref
# Also record SHA and selection for logging and caching.
# ------------------------------------------------------------
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
            } else {
                Write-Warning "Explicit ref '$ref' not found on '$ownerRepo' — falling back."
            }
        }

        if (-not $used) {
            $hasPrefer = git ls-remote --heads origin $Prefer
            if ($hasPrefer) {
                git fetch origin $Prefer --depth 1 | Out-Null
                git checkout -q $Prefer
                $selectedRef = $Prefer
            } else {
                git fetch origin $Fallback --depth 1 | Out-Null
                git checkout -q $Fallback
                $selectedRef = $Fallback
            }
        }

        $sha = (git rev-parse HEAD).Trim()
        Add-Content -Path $shaFile -Value "$ownerRepo $sha"
        Add-Content -Path $selectFile -Value "$ownerRepo|$name|$selectedRef|$sha"

        # Remove token from remote
        git remote set-url origin "https://github.com/$ownerRepo.git" | Out-Null
        Pop-Location
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path

    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

# ------------------------------------------------------------
# Depth-first graph expansion:
#  - clones the repo (once)
#  - recurses dependencies.txt
#  - returns an ordered hashtable list (children first, then self)
# ------------------------------------------------------------
function Build-Chain([string]$ownerRepo, [bool]$includeSelf=$false, [string]$ref=$null) {

    $chain = New-Object System.Collections.Generic.List[hashtable]

    if (-not $cloned.Contains($ownerRepo)) {
        $cloned.Add($ownerRepo) | Out-Null
        Clone-And-Checkout $ownerRepo $ref | Out-Null
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

    if ($includeSelf) {
        $chain.Add(@{ Key=$ownerRepo; Name=$nameMap[$ownerRepo]; Path=$pathMap[$ownerRepo] }) | Out-Null
    }

    return ,$chain
}

# ------------------------------------------------------------
# Build the list of repos (strings: owner/repo) to compile, honoring 'mode'
# ------------------------------------------------------------
$phaseList = New-Object System.Collections.Generic.List[string]

if ($Mode -eq "seeds") {

    Write-Host "----- MODE: seeds (build only specified seed repo(s) + dependencies) -----"

    if (-not [string]::IsNullOrWhiteSpace($Seeds)) {
        $seedList = @($Seeds.Trim().Split("`n")) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and $_.IndexOfAny(@(' ', "`t")) -lt 0 } |
            Where-Object { $_ -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9._/-]+)?$" }

        foreach ($s in $seedList) {
            $sp = Parse-RepoSpec $s
            $chain = Build-Chain $sp.Key $true $sp.Ref
            foreach ($item in $chain) {
                if (-not $phaseList.Contains($item.Key)) { $phaseList.Add($item.Key) | Out-Null }
            }
            Write-Host "Seed: $($sp.Key)"
        }
    }
    else {
        Write-Host "(none)"
    }
}
else {

    Write-Host "----- MODE: caller (build caller repo's dependencies from $DepsFile) -----"

    foreach ($seed in (Lines $DepsFile)) {
        $parsed = Parse-RepoSpec $seed
        $chain  = Build-Chain $parsed.Key $true $parsed.Ref
        foreach ($item in $chain) {
            if (-not $phaseList.Contains($item.Key)) { $phaseList.Add($item.Key) | Out-Null }
        }
        Write-Host "Dep: $($parsed.Key)"
    }

    if ($phaseList.Count -eq 0) {
        Write-Host "(none)"
    }
}

# Optional guard (debugging): ensure only strings entered phase list
# if ($phaseList | Where-Object { $_ -isnot [string] }) {
#     throw "Phase list contains non-string entries. Ensure only repo keys are added (use `$item.Key`)."
# }

# ------------------------------------------------------------
# Merge with de-dup (keep first occurrence)
# ------------------------------------------------------------
$seen   = New-Object System.Collections.Generic.HashSet[string]
$merged = New-Object System.Collections.Generic.List[string]

foreach ($k in $phaseList) {
    if (-not $seen.Contains($k)) {
        $seen.Add($k) | Out-Null
        $merged.Add($k) | Out-Null
    }
}

# ------------------------------------------------------------
# Map owner/repo -> folder name and write _order.txt
# ------------------------------------------------------------
$folderOrder = $merged | ForEach-Object {
    if ($nameMap.ContainsKey($_)) {
        $nameMap[$_]
    }
    else {
        $parts = $_.Split("/")
        if     ($parts.Length -ge 2) { $parts[1] }
        elseif ($parts.Length -eq 1) { $parts[0] }
        else { "unknown" }
    }
}

$folderOrder | Set-Content -Path $orderOut -Encoding utf8

Write-Host "== Final build order =="
Get-Content $orderOut | ForEach-Object { Write-Host " - $_" }

# ------------------------------------------------------------
# Print selection summary (repo -> selected ref @ sha)
# ------------------------------------------------------------
if (Test-Path $selectFile) {
    Write-Host "== Checkout selections =="
    foreach ($line in (Get-Content $selectFile)) {
        $t = $line.Split("|")
        if ($t.Length -ge 4) {
            Write-Host " - $($t[0]) (folder: $($t[1])) -> $($t[2]) @ $($t[3])"
        }
    }
}