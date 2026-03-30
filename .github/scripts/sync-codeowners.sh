#!/usr/bin/env bash
# Syncs .github/CODEOWNERS in target BHoM repos from GitHub team assignments.
#
# Usage: sync-codeowners.sh <repo-list-file>
#
# Environment variables (set by the calling workflow):
#   GH_TOKEN      — installation token for the DevOps GitHub App
#   ORG           — GitHub organisation login
#   DRY_RUN       — 'true' to log intended changes without opening PRs
#   PLATFORM_TEAM — slug of the platform team (default: platform)
#
# Team membership is fully dynamic — all teams assigned to a repo in GitHub
# are written into CODEOWNERS (except the platform team, which is always
# written to the /.github/ line separately). No team list is hardcoded here.
#
# Behaviour per repo:
#   - Queries GitHub for all teams assigned to the repo.
#   - Generates the expected CODEOWNERS content from those assignments.
#   - Skips if the repo's CODEOWNERS already matches the expected content.
#   - Creates branch governance/sync-codeowners-YYYY-MM-DD (datestamped to
#     prevent stale approvals from carrying over across runs).
#   - Closes any open PRs targeting older governance/sync-codeowners-* branches
#     before opening a fresh PR for the new branch.
#   - Failures are collected and reported at the end without stopping the loop.
set -euo pipefail

REPO_FILE="${1:?Usage: sync-codeowners.sh <repo-list-file>}"
BRANCH="governance/sync-codeowners-$(date +%Y-%m-%d)"
BRANCH_PREFIX="governance/sync-codeowners-"
DRY_RUN="${DRY_RUN:-false}"
ORG="${ORG:?ORG must be set}"
PLATFORM_TEAM="${PLATFORM_TEAM:-platform}"
CODEOWNERS_PATH=".github/CODEOWNERS"

SKIPPED=0
UPDATED=0
FAILURES=()

if [ ! -f "$REPO_FILE" ]; then
  echo "::error::Repo list file not found: $REPO_FILE"
  exit 1
fi

git config --global user.name  "bhom-devops[bot]"
git config --global user.email "bhom-devops[bot]@users.noreply.github.com"
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns a sorted list of team slugs assigned to $1, excluding the platform
# team (which is always written to the /.github/ line separately).
get_product_teams() {
  local repo="$1"
  local out
  if ! out=$(gh api "repos/${ORG}/${repo}/teams" --paginate 2>&1); then
    echo "::error::Failed to query teams for ${repo}: ${out}" >&2
    return 1
  fi
  echo "$out" | jq -r "[.[] | .slug] | map(select(. != \"${PLATFORM_TEAM}\")) | sort | .[]"
}

# Generates the expected CODEOWNERS content for a repo.
generate_codeowners() {
  local repo="$1"
  shift
  local teams=("$@")

  echo "# CODEOWNERS — managed by sync-codeowners workflow, do not edit manually."
  echo "# To change ownership, update team assignments in GitHub and re-run the workflow."
  echo ""

  if [ "${#teams[@]}" -gt 0 ]; then
    echo "# Product team(s) own all source code."
    local refs=""
    for slug in "${teams[@]}"; do
      refs="${refs} @${ORG}/${slug}"
    done
    echo "*${refs}"
  else
    echo "# WARNING: no product team assigned to this repo."
    echo "# Assign a team in GitHub and re-run the sync workflow."
  fi

  echo ""
  echo "# Platform team owns all governance and CI configuration."
  echo "/.github/ @${ORG}/${PLATFORM_TEAM}"
}

mkdir -p targets

# ── Preflight: verify the App token can query repo teams ─────────────────────
# This endpoint requires Organisation > Members: Read on the App installation.
# Fail fast here rather than silently mishandling 403s across every repo.
echo "Checking App token has permission to query repository teams..."
if ! gh api "repos/${ORG}/DevOps_Toolkit/teams" --paginate > /dev/null 2>&1; then
  echo "::error::The App token cannot access repo team assignments (GET /repos/{org}/{repo}/teams)."
  echo "::error::Grant 'Organisation > Members: Read' to the GitHub App installation and re-run."
  exit 1
fi
echo "Permission check passed."

# ── Main loop ─────────────────────────────────────────────────────────────────

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "::group::$ORG/$repo"

  # Resolve which product teams are assigned to this repo.
  mapfile -t ASSIGNED_TEAMS < <(get_product_teams "$repo")

  EXPECTED="$(generate_codeowners "$repo" "${ASSIGNED_TEAMS[@]}")"

  # Fetch the current CODEOWNERS content (empty string if file absent).
  CURRENT="$(gh api "repos/${ORG}/${repo}/contents/${CODEOWNERS_PATH}" \
    --jq '.content' 2>/dev/null \
    | base64 --decode 2>/dev/null \
    || true)"

  if [ "$(echo "$CURRENT" | tr -d '[:space:]')" = "$(echo "$EXPECTED" | tr -d '[:space:]')" ]; then
    echo "::notice::$repo already up to date — skipped."
    SKIPPED=$((SKIPPED + 1))
    echo "::endgroup::"
    continue
  fi

  if [ "${#ASSIGNED_TEAMS[@]}" -eq 0 ]; then
    echo "::warning::$repo has no product team assigned — a CODEOWNERS PR will be opened with a warning comment."
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::[dry run] $repo would be updated. Teams: ${ASSIGNED_TEAMS[*]:-none}"
    echo "::endgroup::"
    continue
  fi

  TARGET_DIR="targets/$repo"
  rm -rf "$TARGET_DIR"

  (
    set -euo pipefail

    if ! gh repo clone "$ORG/$repo" "$TARGET_DIR" -- --depth=1 --branch develop --quiet; then
      echo "::error::Failed to clone $ORG/$repo"
      exit 1
    fi

    cd "$TARGET_DIR"

    git checkout -b "$BRANCH"
    mkdir -p .github
    echo "$EXPECTED" > "$CODEOWNERS_PATH"
    git add "$CODEOWNERS_PATH"
    git commit -m "chore: sync CODEOWNERS from team assignments"

    git push origin "$BRANCH"

    # Close any open PRs from older datestamped branches before opening a
    # fresh one, so stale approvals cannot carry forward to new content.
    gh pr list \
      --repo "$ORG/$repo" \
      --state open \
      --json number,headRefName \
      --jq ".[] | select(.headRefName | startswith(\"${BRANCH_PREFIX}\")) | select(.headRefName != \"${BRANCH}\") | .number" \
    | xargs -r -I{} gh pr close {} --repo "$ORG/$repo" --comment "Superseded by a newer sync run."

    TEAM_LIST="${ASSIGNED_TEAMS[*]:-none}"
    PR_URL=$(gh pr create \
      --repo "$ORG/$repo" \
      --head "$BRANCH" \
      --base develop \
      --title "chore: sync CODEOWNERS from team assignments" \
      --body "Automated update of \`.github/CODEOWNERS\` to reflect current GitHub team assignments.

**Assigned product team(s):** \`${TEAM_LIST}\`

This PR was opened by the [Sync CODEOWNERS](https://github.com/${ORG}/DevOps_Toolkit/actions/workflows/sync-codeowners.yml) workflow. Review the diff and merge once the team assignments are settled.

> [!NOTE]
> The \`.github/\` folder is owned by \`@${ORG}/${PLATFORM_TEAM}\` — platform team approval is required to merge.")

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

# ── Step summary ──────────────────────────────────────────────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### CODEOWNERS sync"
    echo ""
    echo "| | Count |"
    echo "|---|---|"
    echo "| PRs opened | $UPDATED |"
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
  echo "::error::Sync failed for ${#FAILURES[@]} repo(s): ${FAILURES[*]}"
  exit 1
fi

echo "::notice::Sync complete. PRs opened: $UPDATED  Skipped: $SKIPPED"
