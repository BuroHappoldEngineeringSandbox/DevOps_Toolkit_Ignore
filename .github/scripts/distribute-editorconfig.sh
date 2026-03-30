#!/usr/bin/env bash
# Distributes config/.editorconfig to all target BHoM repos.
#
# Usage: distribute-editorconfig.sh <repo-list-file>
#
# Environment variables (set by the calling workflow):
#   GH_TOKEN  — installation token for the DevOps GitHub App
#   ORG       — GitHub organisation login
#   DRY_RUN   — 'true' to log intended changes without opening PRs
#
# Behaviour per repo:
#   - Skips if the repo's .editorconfig already matches the canonical file.
#   - Creates branch devops/update-editorconfig-YYYY-MM-DD (datestamped to
#     prevent stale approvals from carrying over if the branch is re-pushed).
#   - Closes any open PRs targeting older devops/update-editorconfig-* branches
#     before opening a fresh PR for the new branch.
#   - Failures are collected and reported at the end without stopping the loop.
set -euo pipefail

REPO_FILE="${1:?Usage: distribute-editorconfig.sh <repo-list-file>}"
CANONICAL_ABS="$(pwd)/config/.editorconfig"
BRANCH="devops/update-editorconfig-$(date +%Y-%m-%d)"
BRANCH_PREFIX="devops/update-editorconfig-"
DRY_RUN="${DRY_RUN:-false}"
ORG="${ORG:?ORG must be set}"

SKIPPED=0
UPDATED=0
FAILURES=()

if [ ! -f "$CANONICAL_ABS" ]; then
  echo "::error::Canonical .editorconfig not found at $CANONICAL_ABS"
  exit 1
fi

if [ ! -f "$REPO_FILE" ]; then
  echo "::error::Repo list file not found: $REPO_FILE"
  exit 1
fi

git config --global user.name  "bhom-devops[bot]"
git config --global user.email "bhom-devops[bot]@users.noreply.github.com"
# Configure git to use the app token for HTTPS authentication.
# gh CLI handles auth via GH_TOKEN automatically; git push requires
# the credential to be embedded in the remote URL explicitly.
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

mkdir -p targets

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "::group::$ORG/$repo"

  TARGET_DIR="targets/$repo"
  rm -rf "$TARGET_DIR"

  if ! gh repo clone "$ORG/$repo" "$TARGET_DIR" -- --depth=1 --branch develop --quiet; then
    echo "::error::Failed to clone $ORG/$repo"
    FAILURES+=("$repo")
    echo "::endgroup::"
    continue
  fi

  # Skip if the repo's .editorconfig already matches the canonical file.
  if diff -q "$CANONICAL_ABS" "$TARGET_DIR/.editorconfig" >/dev/null 2>&1; then
    echo "::notice::$repo already up to date — skipped."
    SKIPPED=$((SKIPPED + 1))
    echo "::endgroup::"
    continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::[dry run] $repo would be updated."
    echo "::endgroup::"
    continue
  fi

  # Run in a subshell so a failure can be caught without exiting the loop.
  (
    set -euo pipefail
    cd "$TARGET_DIR"

    git checkout -b "$BRANCH"
    cp "$CANONICAL_ABS" .editorconfig
    git add .editorconfig
    git commit -m "chore: update .editorconfig from DevOps_Toolkit"

    git push origin "$BRANCH"

    # Close any open PRs from previous runs (older datestamped branches)
    # before opening a fresh one, to avoid accumulating stale PRs.
    gh pr list \
      --repo "$ORG/$repo" \
      --state open \
      --json number,headRefName \
      --jq ".[] | select(.headRefName | startswith(\"${BRANCH_PREFIX}\")) | select(.headRefName != \"${BRANCH}\") | .number" \
    | xargs -r -I{} gh pr close {} --repo "$ORG/$repo" --comment "Superseded by a newer sync run."

    PR_URL=$(gh pr create \
      --repo "$ORG/$repo" \
      --head "$BRANCH" \
      --base develop \
      --title "chore: update .editorconfig" \
      --body "Automated update of \`.editorconfig\` from [DevOps_Toolkit](https://github.com/${ORG}/DevOps_Toolkit/blob/main/config/.editorconfig).

Formatting rules are managed centrally in DevOps_Toolkit. This PR was opened automatically.

To fix formatting issues locally before opening a PR:
\`\`\`bash
dotnet format
\`\`\`")

    echo "::notice::PR opened: $PR_URL"
  ) || {
    echo "::error::Failed to update $repo"
    FAILURES+=("$repo")
    echo "::endgroup::"
    continue
  }

  UPDATED=$((UPDATED + 1))
  echo "::endgroup::"
done < "$REPO_FILE"

# ── Step summary ─────────────────────────────────────────────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### .editorconfig distribution"
    echo ""
    echo "| | Count |"
    echo "|---|---|"
    echo "| Updated | $UPDATED |"
    echo "| Already up to date | $SKIPPED |"
    echo "| Failed | ${#FAILURES[@]} |"

    if [ "${#FAILURES[@]}" -gt 0 ]; then
      echo ""
      echo "**Failed repos:**"
      for r in "${FAILURES[@]}"; do
        echo "- \`$r\`"
      done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "::error::Distribution failed for ${#FAILURES[@]} repo(s): ${FAILURES[*]}"
  exit 1
fi

echo "::notice::Distribution complete. Updated: $UPDATED  Skipped: $SKIPPED"
