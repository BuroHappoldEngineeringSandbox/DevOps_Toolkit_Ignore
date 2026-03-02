param(
    [string]$DepsFile = "dependencies.txt",
    [string]$ExtraRepos = "",
    [string]$DotNetVersion = "10.x",
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$depsDir = Join-Path $root 'deps'
$shaFile = Join-Path $depsDir '_shas.txt'
$orderOut = Join-Path $depsDir '_order.txt'
$selectionOut = Join-Path $depsDir '_selection.txt'

if (Test-Path $selectionOut) { Remove-Item $selectionOut -Force }

function Lines([string]$path) {
    if (Test-Path $path) {
        return Get-Content $path |
            Where-Object { $_ -and -not $_.Trim().StartsWith("#") } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    }
    @()
}

function Parse-RepoSpec([string]$spec) {
    $ref = $null
    if ($spec.Contains("@")) {
        $parts = $spec.Split("@", 2)
        return @{ Key = $parts[0].Trim(); Ref = $parts[1].Trim() }
    }
    return @{ Key = $spec; Ref = $null }
}

# Determine prefer / fallback branch based on PR or workflow context
$Prefer = $env:PR_BRANCH
if (-not $Prefer -or $Prefer -eq "") {
    $ref = $env:GITHUB_REF_NAME
    if ($ref -and -not $ref.StartsWith("tags/")) { $Prefer = $ref }
    else { $Prefer = "main" }
}

$Fallback = $env:BASE_BRANCH
if (-not $Fallback -or $Fallback -eq "") { $Fallback = "main" }

$cloned = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}
$pathMap = @{}

function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $parts = $ownerRepo.Split("/")
    $name = $parts[1]
    $path = Join-Path $depsDir $name

    if (-not (Test-Path (Join-Path $path ".git"))) {

        $url = "https://x-access-token:$env:DEP_TOKEN@github.com/$ownerRepo.git"
        git clone $url $path --no-tags --depth 1 | Out-Null

        Push-Location $path

        $used = $false
        $selectedRef = $null

        if ($ref) {
            $hasHead = git ls-remote --heads origin $ref
            $hasTag  = git ls-remote --tags origin $ref
            if ($hasHead -or $hasTag) {
                git fetch origin $ref --depth 1 | Out-Null
                git checkout -q $ref
                $selectedRef = $ref
                $used = $true
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
        Add-Content -Path $selectionOut -Value "$ownerRepo|$name|$selectedRef|$sha"

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
    $file = Join-Path $repoPath "dependencies.txt"

    if (Test-Path $file) {
        foreach ($line in (Lines $file)) {
            $p = Parse-RepoSpec $line
            $childList = Build-Chain $p.Key $true $p.Ref
            foreach ($c in $childList) { $chain.Add($c) | Out-Null }
        }
    }

    if ($includeSelf) { $chain.Add($ownerRepo) | Out-Null }

    return ,$chain
}

### PHASE A
$phaseA = New-Object System.Collections.Generic.List[string]
foreach ($seed in (Lines $DepsFile)) {
    $sp = Parse-RepoSpec $seed
    $chain = Build-Chain $sp.Key $true $sp.Ref
    foreach ($item in $chain) {
        if (-not $phaseA.Contains($item)) { $phaseA.Add($item) | Out-Null }
    }
}

### PHASE B
$phaseB = New-Object System.Collections.Generic.List[string]
if ($ExtraRepos) {
    $lines = $ExtraRepos.Split("`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }

    foreach ($seed in $lines) {
        $sp = Parse-RepoSpec $seed
        $chain = Build-Chain $sp.Key $true $sp.Ref
        foreach ($item in $chain) {
            if (-not $phaseB.Contains($item)) { $phaseB.Add($item) | Out-Null }
        }
    }
}

# Merge
$merged = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string]

foreach ($k in $phaseA + $phaseB) {
    if (-not $seen.Contains($k)) { $seen.Add($k) | Out-Null; $merged.Add($k) | Out-Null }
}

# Resolve folder names
$folderOrder = $merged | ForEach-Object {
    $parts = $_ -split '/'
    $parts[1]
}

$folderOrder | Set-Content -Path $orderOut -Encoding utf8