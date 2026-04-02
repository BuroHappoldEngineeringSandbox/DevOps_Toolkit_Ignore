# upload-sarifs.ps1 — patches and uploads SARIF files to GitHub code scanning.
# Expects: cwd = caller repo root, compliance-sarifs/*.sarif produced by run-checks.ps1.
#          GH_TOKEN env var set with security-events:write permission.
#
# Each SARIF file is patched with runs[].automationDetails.id = "<category>" so that
# GitHub code-scanning treats each check as a distinct tool run. The payload is then
# gzip-compressed and base64-encoded as required by the code-scanning upload API.
# Failed uploads emit a warning (non-fatal) so other checks can still be uploaded.
#
# Parameters:
#   -Repo   GitHub repository slug (e.g. BHoM/BHoM_Engine).
#   -Ref    Git ref (e.g. refs/pull/123/merge).
#   -Sha    Commit SHA.

param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Sha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($sarifFile in Get-ChildItem compliance-sarifs -Filter "*.sarif" -ErrorAction SilentlyContinue) {
    $checkName = $sarifFile.BaseName -replace '^compliance-', ''
    $category  = "bhom-compliance-$checkName-pr-delta"

    # Inject automationDetails.id — "category" is not a separate API field; it is conveyed
    # inside the SARIF payload via runs[].automationDetails.id.
    $sarifJson = Get-Content $sarifFile.FullName -Raw | ConvertFrom-Json -Depth 20
    foreach ($run in $sarifJson.runs) {
        if ($null -eq $run.PSObject.Properties["automationDetails"]) {
            $run | Add-Member -NotePropertyName "automationDetails" `
                              -NotePropertyValue ([pscustomobject]@{ id = $category }) -Force
        } else {
            $run.automationDetails.id = $category
        }
    }
    $patchedSarif = $sarifJson | ConvertTo-Json -Depth 20 -Compress

    # gzip + base64 — required encoding for the code-scanning SARIF upload API.
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($patchedSarif)
    $ms      = [System.IO.MemoryStream]::new()
    $gz      = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close()
    $encoded = [System.Convert]::ToBase64String($ms.ToArray())

    gh api "repos/$Repo/code-scanning/sarifs" `
        -X POST `
        --field "sarif=$encoded" `
        --field "ref=$Ref" `
        --field "commit_sha=$Sha" `
        --field "tool_name=BHoM Compliance - $checkName"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "::warning::SARIF upload failed for check: $checkName"
    } else {
        Write-Host "Uploaded SARIF for check: $checkName (category: $category)"
    }
}
