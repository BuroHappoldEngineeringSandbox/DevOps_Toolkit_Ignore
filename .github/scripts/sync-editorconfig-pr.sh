#!/usr/bin/env bash
# sync-editorconfig-pr.sh
#
# Opens or updates a PR in a target repo to sync the canonical .editorconfig.
# Expects to run from the DevOps_Toolkit checkout root.
#
# Required environment variables:
#   GH_TOKEN       - PAT with repo scope for cross-repo API calls
#   TARGETS        - space-separated list of repo names to sync
#   DRY_RUN        - 'true' to log targets without making any changes
#   ORG            - GitHub organisation name
#   CANONICAL      - path to the canonical .editorconfig (default: config/.editorconfig)
#   PR_BODY_FILE   - path to the PR body markdown template
#
# Usage: bash .github/scripts/sync-editorconfig-pr.sh

set -e

CANONICAL="${CANONICAL:-config/.editorconfig}"
PR_BODY_FILE="${PR_BODY_FILE:-.github/templates/sync-editorconfig-pr.md}"
SYNC_BRANCH="chore/sync-editorconfig"
COMMIT_MSG="chore: sync .editorconfig from DevOps_Toolkit"
PR_TITLE="chore: sync .editorconfig from DevOps_Toolkit"

if [ -z "$GH_TOKEN" ]; then
  echo "::error title=Missing token::GH_TOKEN is not set. This workflow requires a PAT with 'repo' scope."
  echo "::error::Set GH_TOKEN as an organisation secret in GitHub → Settings → Secrets → Actions."
  exit 1
fi

if [ ! -f "$CANONICAL" ]; then
  echo "::error::Canonical EditorConfig not found at '$CANONICAL'."
  exit 1
fi

if [ ! -f "$PR_BODY_FILE" ]; then
  echo "::error::PR body template not found at '$PR_BODY_FILE'."
  exit 1
fi

if [ -z "$TARGETS" ]; then
  echo "::notice::No target repos specified — nothing to sync."
  exit 0
fi

pr_body=$(cat "$PR_BODY_FILE")
file_content_b64=$(base64 -w 0 "$CANONICAL")

# ── sync_repo: sync .editorconfig to a single repo ────────────────────────────
sync_repo() {
  local repo="$1"
  local full="$ORG/$repo"

  echo "::group::$full"

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::DRY RUN — would sync to $full"
    echo "::endgroup::"
    return
  fi

  # Get default branch — surface the error if the token lacks access to this repo
  local default_branch
  local repo_api_error
  repo_api_error=$(gh api "repos/$full" --jq '.default_branch' 2>&1)
  local repo_api_exit=$?

  if [ $repo_api_exit -ne 0 ]; then
    echo "::warning::Could not access $full (exit $repo_api_exit). Check GH_TOKEN has 'repo' scope for this repo."
    echo "::warning::API response: $repo_api_error"
    echo "::endgroup::"
    return
  fi
  default_branch="$repo_api_error"

  # Get SHA of default branch tip
  local base_sha
  local sha_error
  sha_error=$(gh api "repos/$full/git/ref/heads/$default_branch" \
    --jq '.object.sha' 2>&1)
  local sha_exit=$?

  if [ $sha_exit -ne 0 ] || [ -z "$sha_error" ]; then
    echo "::warning::Could not get SHA for $full/$default_branch (exit $sha_exit)."
    echo "::warning::API response: $sha_error"
    echo "::endgroup::"
    return
  fi
  local base_sha="$sha_error"

  # Create or reset the sync branch
  # Use '.ref // empty' so jq returns nothing (not the string "null") for missing refs,
  # ensuring bash treats a non-existent branch as an empty string.
  local existing_ref
  existing_ref=$(gh api "repos/$full/git/ref/heads/$SYNC_BRANCH" \
    --jq '.ref // empty' 2>/dev/null || true)

  if [ -z "$existing_ref" ]; then
    echo "Creating branch '$SYNC_BRANCH'..."
    gh api "repos/$full/git/refs" \
      --method POST \
      --field ref="refs/heads/$SYNC_BRANCH" \
      --field sha="$base_sha" > /dev/null
  else
    echo "Branch '$SYNC_BRANCH' exists — resetting to $default_branch tip..."
    gh api "repos/$full/git/refs/heads/$SYNC_BRANCH" \
      --method PATCH \
      --field sha="$base_sha" \
      --field force=true > /dev/null
  fi

  # Commit the canonical .editorconfig (create or update)
  # Use '.sha // empty' for the same null-safety reason as the branch ref check above.
  local existing_file_sha
  existing_file_sha=$(gh api "repos/$full/contents/.editorconfig?ref=$SYNC_BRANCH" \
    --jq '.sha // empty' 2>/dev/null || true)

  local api_args=(
    "repos/$full/contents/.editorconfig"
    --method PUT
    --field message="$COMMIT_MSG"
    --field content="$file_content_b64"
    --field branch="$SYNC_BRANCH"
  )
  [ -n "$existing_file_sha" ] && api_args+=(--field sha="$existing_file_sha")

  gh api "${api_args[@]}" > /dev/null
  echo ".editorconfig committed to '$SYNC_BRANCH'."

  # Open a PR if one does not already exist
  local existing_pr
  existing_pr=$(gh pr list \
    --repo "$full" \
    --head "$SYNC_BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number' 2>/dev/null || true)

  if [ -n "$existing_pr" ]; then
    echo "::notice::PR #$existing_pr already open — branch updated, PR remains."
  else
    local pr_url
    pr_url=$(gh pr create \
      --repo "$full" \
      --head "$SYNC_BRANCH" \
      --base "$default_branch" \
      --title "$PR_TITLE" \
      --body "$pr_body" 2>/dev/null || true)

    if [ -n "$pr_url" ]; then
      echo "::notice::PR opened: $pr_url"
    else
      echo "::warning::Branch updated but PR creation failed for $full."
    fi
  fi

  echo "::endgroup::"
}

# ── Main: iterate over all target repos ───────────────────────────────────────
for repo in $TARGETS; do
  sync_repo "$repo"
done
