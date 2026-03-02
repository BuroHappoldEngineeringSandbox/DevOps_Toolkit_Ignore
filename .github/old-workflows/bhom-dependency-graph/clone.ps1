#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter()][string]$Token,
  [Parameter()][string]$DepsFile = "dependencies.txt",
  [Parameter()][string]$ExtraRepos = "",
  [Parameter()][string]$PRBranch = "",
  [Parameter()][string]$BaseBranch = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Prepare workspace folders
$root = (Get-Location).Path
$depsDir = Join-Path $root 'deps'
$shaFile = Join-Path $depsDir '_shas.txt'
New-Item -ItemType Directory -Force -Path $depsDir | Out-Null
New-Item -ItemType File -Force -Path $shaFile   | Out-Null

function Lines([string]$path) {
  if (Test-Path $path) {
    return Get-Content $path |
      Where-Object { $_ -and -not $_.Trim().StartsWith('#') } |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
  }
  @()
}

# Seed: deps_file + extra_repos
$seeds = @()
$seeds += Lines $DepsFile
if ($ExtraRepos) {
  $seeds += @($ExtraRepos.Split("`n")) |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }
}
if ($seeds.Count -eq 0) {
  Write-Host "No dependencies — exiting early."
  exit 0
}

# Branch preferences
$Prefer   = if ($PRBranch)   { $PRBranch }   else { 'feature/unknown' }
$Fallback = if ($BaseBranch) { $BaseBranch } else { 'main' }

$seen = New-Object System.Collections.Generic.HashSet[string]

function CloneOne([string]$ownerRepo) {
  $parts = $ownerRepo.Split('/')
  if ($parts.Count -ne 2) { return }
  $name = $parts[1]
  $target = Join-Path $depsDir $name
  if (Test-Path (Join-Path $target '.git')) { return }

  $url = "https://x-access-token:$Token@github.com/$ownerRepo.git"
  git clone $url $target --no-tags --depth 1 | Out-Null

  Push-Location $target
  $hasPrefer = git ls-remote --heads origin $Prefer
  if ($hasPrefer) {
    git fetch origin $Prefer --depth 1 | Out-Null
    git checkout -q $Prefer
  } else {
    git fetch origin $Fallback --depth 1 | Out-Null
    git checkout -q $Fallback
  }

  $sha = (git rev-parse HEAD).Trim()
  Add-Content -Path $shaFile -Value "$name $sha"
  Pop-Location
}

function Recurse([string]$r) {
  $name = ($r.Split('/'))[1]
  if ($seen.Contains($name)) { return }
  $seen.Add($name) | Out-Null

  CloneOne $r

  $depFile = Join-Path (Join-Path $depsDir $name) 'dependencies.txt'
  if (Test-Path $depFile) {
    Lines $depFile | ForEach-Object { Recurse $_ }
  }
}

$seeds | ForEach-Object { Recurse $_ }

Write-Host "Dependency SHAs:"
Get-Content $shaFile | Sort-Object