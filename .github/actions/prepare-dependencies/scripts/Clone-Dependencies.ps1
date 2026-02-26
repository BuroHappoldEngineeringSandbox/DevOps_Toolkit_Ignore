# Clone-Dependencies.ps1
# Purpose: Parse dependency list, shallow clone, checkout ref (if provided), log effective SHA.

# Fail fast on any error.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Read inputs from environment (set by the composite action)
$dependencies = $env:DEPENDENCIES
$defaultOrg   = $env:DEFAULT_ORG
$token        = $env:TOKEN

# Ensure base folder exists
New-Item -ItemType Directory -Force -Path "deps" | Out-Null

# If a token is available, ensure HTTPS pushes/pulls will use it (do NOT print it)
if (-not [string]::IsNullOrWhiteSpace($token)) {
    git config --global url."https://x-access-token:$($token)@github.com/".insteadOf "https://github.com/"
}

# Parse comma-separated list into ordered array
$list = @()
foreach ($part in @($dependencies.Split(','))) {
    $t = $part.Trim()
    if ($t) { $list += $t }
}

if ($list.Count -eq 0) {
    Write-Host "No dependencies parsed from input. Nothing to clone."
    exit 0
}

foreach ($d in $list) {
    $spec = $d
    $ref  = ""

    if ($d -match "@") {
        $parts = $d.Split("@", 2)
        $spec  = $parts[0].Trim()
        $ref   = $parts[1].Trim()
    }

    if ($spec.Contains("/")) {
        $owner = $spec.Split("/")[0]
        $repo  = $spec.Split("/")[1]
    } else {
        $owner = $defaultOrg
        $repo  = $spec
    }

    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        Write-Error "Invalid dependency spec '$d' (owner/repo could not be determined)."
        throw
    }

    $folder = "$owner`_$repo"
    $url    = "https://github.com/$owner/$repo.git"
    $path   = "deps/$folder"

    # Build a readable suffix for the log line without using the ? alias
    $suffix = if ([string]::IsNullOrEmpty($ref)) { "" } else { "@$ref" }
    Write-Host "::group::Clone $owner/$repo $suffix"


    try {
        # Quick access check with helpful error if private/inaccessible
        git ls-remote $url *> $null
    }
    catch {
        Write-Error "Cannot access $owner/$repo. Ensure the token has 'contents: read'."
        throw
    }

    try {
        git clone --depth 1 $url $path
    }
    catch {
        Write-Error "Failed to clone $owner/$repo from $url."
        throw
    }

    if (-not (Test-Path $path)) {
        Write-Error "Clone target path not found: $path (clone failed)"
        throw
    }

    if (-not [string]::IsNullOrEmpty($ref)) {
        Push-Location $path
        git fetch --all --tags --prune
        try {
            git checkout $ref
        }
        catch {
            Write-Error "Failed to checkout ref '$ref' in $owner/$repo."
            throw
        }
        Pop-Location
    }

    # Record the effective commit for traceability
    Push-Location $path
    $sha = (git rev-parse HEAD)
    Write-Host "Checked out $owner/$repo @ $sha into $path"
    Pop-Location

    Write-Host "::endgroup::"
}