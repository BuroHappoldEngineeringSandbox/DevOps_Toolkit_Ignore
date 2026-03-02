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
        $parts = $spec.Split("@",2)
        $spec  = $parts[0].Trim()
        $ref   = $parts[1].Trim()
    }
    return @{ Key=$spec; Ref=$ref }
}

# Branch selection (PR branch preferred; fallback to base or main)
$Prefer   = $env:PR_BRANCH
if (-not $Prefer -or $Prefer -eq "") { $Prefer = "feature/unknown" }

$Fallback = $env:BASE_BRANCH
if (-not $Fallback -or $Fallback -eq "") { $Fallback = "main" }

# Track cloned repos and folder mapping
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}
$pathMap = @{}

function Get-FolderName([string]$ownerRepo) {
    $parts = $ownerRepo.Split("/")
    if ($parts.Length -ge 2) { return $parts[1] }
    if ($parts.Length -eq 1 -and $parts[0] -ne "") { return $parts[0] }
    return "unknown"
}

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

function Build-Chain([string]$ownerRepo, [bool]$includeSelf=$false, [string]$ref=$null) {

    $chain = New-Object System.Collections.Generic.List[hashtable]

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

    if ($includeSelf) { $chain.Add(@{ Key=$ownerRepo; Name=$nameMap[$ownerRepo]; Path=$pathMap[$ownerRepo] }) | Out-Null }
    return ,$chain
}

# Build the list of repos to compile (strings: owner/repo), honoring mode
$phaseList = New-Object System.Collections.Generic.List[string]

if ($Mode -eq "seeds") {

    Write-Host "----- MODE: seeds (build only specified seed repo(s) + dependencies) -----"

    if ($Seeds) {
        $seedList = @($Seeds.Split("`n")) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }

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
    }

    if ($phaseList.Count -eq 0) {
        Write-Host "(none)"
    }
    else {
        $phaseList | ForEach-Object { Write-Host "Dep: $_" }
    }
}

# Merge with de-dup (keep first occurrence)
$seen   = New-Object System.Collections.Generic.HashSet[string]
$merged = New-Object System.Collections.Generic.List[string]

foreach ($k in $phaseList) {
    if (-not $seen.Contains($k)) {
        $seen.Add($k) | Out-Null
        $merged.Add($k) | Out-Null
    }
}

# Map owner/repo -> folder name
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

if (Test-Path $selectFile) {
    Write-Host "== Checkout selections =="
    foreach ($line in (Get-Content $selectFile)) {
        $t = $line.Split("|")
        if ($t.Length -ge 4) {
            Write-Host " - $($t[0]) (folder: $($t[1])) -> $($t[2]) @ $($t[3])"
        }
    }
}