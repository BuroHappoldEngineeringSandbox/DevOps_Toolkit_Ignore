param(
    [string]$DepsFile         = "dependencies.txt",
    [string]$Mode             = "caller",   # "caller" | "seeds"
    [string]$Seeds            = "",         # used only when Mode = "seeds"
    [string]$AdditionalSeeds  = ""          # used only when Mode = "caller"; appended after caller graph
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root       = (Get-Location).Path
$depsDir    = Join-Path $root "deps"        # metadata only (_shas, _order, _selection)
$cloneRoot  = "C:\bhom-deps"                 # isolated clone root, outside any workspace
$shaFile    = Join-Path $depsDir "_shas.txt"
$orderOut   = Join-Path $depsDir "_order.txt"
$selectFile = Join-Path $depsDir "_selection.txt"

New-Item -ItemType Directory -Force -Path $cloneRoot | Out-Null

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
# Branch preferences:
#   1) explicit @ref; 2) PR_BRANCH; 3) BASE_BRANCH; 4) "main"
# ------------------------------------------------------------
$Prefer   = $env:PR_BRANCH
if ([string]::IsNullOrWhiteSpace($Prefer)) { $Prefer = "feature/unknown" }

$Fallback = $env:BASE_BRANCH
if ([string]::IsNullOrWhiteSpace($Fallback)) { $Fallback = "develop" }

# ------------------------------------------------------------
# Tracking and maps
# ------------------------------------------------------------
$cloned  = New-Object System.Collections.Generic.HashSet[string]
$nameMap = @{}  # owner/repo -> folder
$pathMap = @{}  # owner/repo -> path

function Get-FolderName([string]$ownerRepo) {
    $parts = $ownerRepo.Split("/")
    if ($parts.Length -ge 2) { return $parts[1] }
    if ($parts.Length -eq 1 -and $parts[0] -ne "") { return $parts[0] }
    return "unknown"
}

# ------------------------------------------------------------
# Clone + checkout with selection recording
# ------------------------------------------------------------
function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $name = Get-FolderName $ownerRepo
    $path = Join-Path $cloneRoot $name

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

        git remote set-url origin "https://github.com/$ownerRepo.git" | Out-Null
        Pop-Location

        Write-Host "::notice title=Dependency checkout::$ownerRepo → $selectedRef @ $($sha.Substring(0,7))"
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path

    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

# ------------------------------------------------------------
# Depth-first expansion: children first, then self
# Returns List[hashtable] of entries { Key, Name, Path }
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

    return $chain
}

# ------------------------------------------------------------
# Compute the set to build (strings), honoring 'mode'
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

# ------------------------------------------------------------
# Additional seeds (caller mode only)
# Appended after the caller graph so that caller assemblies
# are built first, matching the dependency order BHoMBot used
# when it resolved the caller repo before Test_Toolkit etc.
# Ignored when mode=seeds (seeds already accepts multiple repos).
# ------------------------------------------------------------
if ($Mode -ne "seeds" -and -not [string]::IsNullOrWhiteSpace($AdditionalSeeds)) {
    Write-Host "----- Additional seeds (appended to caller graph) -----"

    $extraList = @($AdditionalSeeds.Trim().Split("`n")) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and $_.IndexOfAny(@(' ', "`t")) -lt 0 } |
        Where-Object { $_ -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9._/-]+)?$" }

    foreach ($s in $extraList) {
        $sp    = Parse-RepoSpec $s
        $chain = Build-Chain $sp.Key $true $sp.Ref
        foreach ($item in $chain) {
            if (-not $phaseList.Contains($item.Key)) {
                $phaseList.Add($item.Key) | Out-Null
            }
        }
        Write-Host "  Extra seed: $($sp.Key)"
    }
}

# ------------------------------------------------------------
# Merge with de-dup (keep first)
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
# Write _order.txt as owner/repo lines (Build-Dependencies derives path from repo name).
# ------------------------------------------------------------
$merged | Set-Content -Path $orderOut -Encoding utf8

Write-Host "== Final build order (owner/repo) =="
Get-Content $orderOut | ForEach-Object { Write-Host "  $_ → C:\bhom-deps\$($_.Split('/')[1])" }

# ------------------------------------------------------------
# Step summary: dependency checkout table
# ------------------------------------------------------------
if (Test-Path $selectFile) {
    Write-Host ""
    Write-Host "== Checkout selections =="

    $mdLines = @("### Dependency graph — checkout selections", "",
                 "| Repository | Folder | Branch | SHA |",
                 "|---|---|---|---|")

    foreach ($line in (Get-Content $selectFile)) {
        $t = $line.Split("|")
        if ($t.Length -ge 4) {
            $shortSha = if ($t[3].Length -ge 7) { $t[3].Substring(0,7) } else { $t[3] }
            Write-Host "  $($t[0]) → $($t[2]) @ $shortSha"
            $mdLines += "| ``$($t[0])`` | $($t[1]) | $($t[2]) | ``$shortSha`` |"
        }
    }

    if ($env:GITHUB_STEP_SUMMARY) {
        $mdLines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}