param(
    [string]$DepsFile         = "dependencies.txt",
    [string]$Mode             = "caller",   # "caller" | "seeds"
    [string]$Seeds            = "",         # used only when Mode = "seeds"
    [string]$AdditionalSeeds  = "",         # used only when Mode = "caller"; appended after caller graph
    [string]$CloneRoot        = "C:\bhom-deps"  # isolated clone root, outside any workspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root       = (Get-Location).Path
$depsDir    = Join-Path $root "deps"        # metadata only (_shas, _order, _selection)
$cloneRoot  = $CloneRoot
$shaFile    = Join-Path $depsDir "_shas.txt"
$orderOut   = Join-Path $depsDir "_order.txt"
$selectFile = Join-Path $depsDir "_selection.txt"

New-Item -ItemType Directory -Force -Path $cloneRoot | Out-Null

if (Test-Path $selectFile) { Remove-Item $selectFile -Force }

# Reads non-blank, non-comment lines from a file and validates format.
# Valid forms: owner/repo or owner/repo@branch|tag|sha (no whitespace).
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
            ForEach-Object {
                if (-not ($_ -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(@[A-Za-z0-9._/-]+)?$")) {
                    throw "Malformed dependency entry (invalid format): '$_'. Expected 'owner/repo' or 'owner/repo@ref' using alphanumeric characters, dots, underscores, or hyphens."
                }
                $_
            }
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

# Branch preference: explicit @ref → PR_BRANCH → BASE_BRANCH → remote default
# $Prefer is null when PR_BRANCH is unset (push/dispatch events) so the ls-remote
# round-trip is skipped entirely rather than probing a sentinel that never exists.
$Prefer   = if ([string]::IsNullOrWhiteSpace($env:PR_BRANCH))   { $null } else { $env:PR_BRANCH.Trim() }
$Fallback = if ([string]::IsNullOrWhiteSpace($env:BASE_BRANCH)) { 'develop' } else { $env:BASE_BRANCH.Trim() }

$cloned  = New-Object System.Collections.Generic.HashSet[string]
$visited = New-Object System.Collections.Generic.HashSet[string]  # guards against circular deps
$nameMap = @{}  # owner/repo -> folder
$pathMap = @{}  # owner/repo -> path

# Route all GitHub HTTPS clones through the token via insteadOf so the token never appears
# in git command arguments, process listings, or git's own error messages.
# DEP_TOKEN is masked in Actions logs; writing it into a URL rewrite rule instead of a clone
# URL also means cloned repos' .git/config files never contain the credential.
if (-not [string]::IsNullOrWhiteSpace($env:DEP_TOKEN)) {
    git config --global url."https://x-access-token:$($env:DEP_TOKEN)@github.com/".insteadOf "https://github.com/"
}

function Get-FolderName([string]$ownerRepo) {
    $parts = $ownerRepo.Split("/")
    if ($parts.Length -ge 2) { return $parts[1] }
    if ($parts.Length -eq 1 -and $parts[0] -ne "") { return $parts[0] }
    return "unknown"
}

function Clone-And-Checkout([string]$ownerRepo, [string]$ref) {

    $name = Get-FolderName $ownerRepo
    $path = Join-Path $cloneRoot $name

    if (-not (Test-Path (Join-Path $path ".git"))) {

        git clone "https://github.com/$ownerRepo.git" $path --no-tags --depth 1 | Out-Null

        $selectedRef = $null
        Push-Location $path
        try {
            $used = $false

            if ($ref) {
                $hasHead = git ls-remote --heads origin $ref
                $hasTag  = git ls-remote --tags  origin $ref
                if ($hasHead -or $hasTag) {
                    git fetch origin $ref --depth 1 | Out-Null
                    git checkout -q FETCH_HEAD
                    if ($LASTEXITCODE -ne 0) { throw "git checkout FETCH_HEAD failed for '$ownerRepo' (ref=$ref)" }
                    $selectedRef = $ref
                    $used = $true
                } else {
                    Write-Warning "Explicit ref '$ref' not found on '$ownerRepo' — falling back."
                }
            }

            if (-not $used) {
                $hasPrefer   = if ($Prefer)   { git ls-remote --heads origin $Prefer }   else { $null }
                $hasFallback = git ls-remote --heads origin $Fallback
                if ($hasPrefer) {
                    git fetch origin $Prefer --depth 1 | Out-Null
                    git checkout -q FETCH_HEAD
                    if ($LASTEXITCODE -ne 0) { throw "git checkout FETCH_HEAD failed for '$ownerRepo' (ref=$Prefer)" }
                    $selectedRef = $Prefer
                } elseif ($hasFallback) {
                    git fetch origin $Fallback --depth 1 | Out-Null
                    git checkout -q FETCH_HEAD
                    if ($LASTEXITCODE -ne 0) { throw "git checkout FETCH_HEAD failed for '$ownerRepo' (ref=$Fallback)" }
                    $selectedRef = $Fallback
                } else {
                    # Neither PR branch nor base branch exist on this dep repo — fall back to
                    # its remote default branch (main / next / etc.)
                    git fetch origin HEAD --depth 1 | Out-Null
                    git checkout -q FETCH_HEAD
                    if ($LASTEXITCODE -ne 0) { throw "git checkout FETCH_HEAD failed for '$ownerRepo' (remote default)" }
                    $defaultRef = (git ls-remote --symref origin HEAD |
                        Select-String 'ref: refs/heads/(\S+)\s+HEAD' |
                        ForEach-Object { $_.Matches[0].Groups[1].Value } |
                        Select-Object -First 1)
                    $selectedRef = if ($defaultRef) { $defaultRef } else { "(remote default)" }
                }
            }

            $sha = (git rev-parse HEAD).Trim()
            Add-Content -Path $shaFile    -Value "$ownerRepo $sha"
            Add-Content -Path $selectFile -Value "$ownerRepo|$name|$selectedRef|$sha"
        }
        finally {
            Pop-Location
        }

        Write-Host "::notice title=Dependency checkout::$ownerRepo → $selectedRef @ $($sha.Substring(0,7))"
    }

    $nameMap[$ownerRepo] = $name
    $pathMap[$ownerRepo] = $path

    return @{ Key=$ownerRepo; Name=$name; Path=$path }
}

# Depth-first expansion: children first, then self. Returns List[hashtable] { Key, Name, Path }.
function Build-Chain([string]$ownerRepo, [bool]$includeSelf=$false, [string]$ref=$null) {

    $chain = New-Object System.Collections.Generic.List[hashtable]

    if (-not $cloned.Contains($ownerRepo)) {
        $cloned.Add($ownerRepo) | Out-Null
        Clone-And-Checkout $ownerRepo $ref | Out-Null
    }

    # Guard against circular dependencies: if this repo's transitive graph has already
    # been expanded in an ancestor call, skip re-expansion to prevent infinite recursion.
    if ($visited.Contains($ownerRepo)) {
        if ($includeSelf -and $pathMap.ContainsKey($ownerRepo)) {
            $chain.Add(@{ Key=$ownerRepo; Name=$nameMap[$ownerRepo]; Path=$pathMap[$ownerRepo] }) | Out-Null
        }
        return $chain
    }
    $visited.Add($ownerRepo) | Out-Null

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

# Additional seeds (caller mode only): appended after caller graph so caller assemblies
# build first. Ignored when mode=seeds since that mode already accepts multiple repos.
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

$seen   = New-Object System.Collections.Generic.HashSet[string]
$merged = New-Object System.Collections.Generic.List[string]

foreach ($k in $phaseList) {
    if (-not $seen.Contains($k)) {
        $seen.Add($k) | Out-Null
        $merged.Add($k) | Out-Null
    }
}

# Write _order.txt — Build-Dependencies derives clone path from repo name.
# Always create the file (even when empty) so Build-Dependencies.ps1's Get-Content never throws.
if ($merged.Count -gt 0) {
    $merged | Set-Content -Path $orderOut -Encoding utf8
} else {
    [string]::Empty | Set-Content -Path $orderOut -Encoding utf8
}

Write-Host "== Final build order (owner/repo) =="
if ($merged.Count -gt 0) {
    Get-Content $orderOut | ForEach-Object { Write-Host "  $_ → $cloneRoot\$($_.Split('/')[1])" }
} else {
    Write-Host "  (no dependencies)"
}

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