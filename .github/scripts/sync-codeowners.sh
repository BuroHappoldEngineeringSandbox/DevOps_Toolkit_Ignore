#!/usr/bin/env bash
# Syncs .github/CODEOWNERS in target BHoM repos from config/repo-ownership.yml.
#
# Usage: sync-codeowners.sh <repo-list-file>
#
# Environment variables (set by the calling workflow):
#   GH_TOKEN      — installation token for the DevOps GitHub App
#   ORG           — GitHub organisation login
#   DRY_RUN       — 'true' to log intended changes without opening PRs
#   PLATFORM_TEAM — slug of the platform team (default: platform)
#
# Ownership source of truth: config/repo-ownership.yml in DevOps_Toolkit.
# Each repo maps to exactly one discipline team slug. GitHub team assignments
# are cross-checked for write (or higher) access; a warning is emitted if the
# named team lacks it — CODEOWNERS is only effective in GitHub when the owning
# team has at least write access to the repo.
#
# Platform-owned repos (discipline team = platform team) generate a single-line
# CODEOWNERS giving the platform team full ownership of the repository.
#
# Behaviour per repo:
#   - Resolves the discipline team from config/repo-ownership.yml.
#   - Skips with a warning if no entry exists in the map (counted separately from failures).
#   - Cross-checks that the team has write (or higher) access in GitHub (warning only).
#   - Generates the expected CODEOWNERS content.
#   - In dry-run mode, prints the full expected CODEOWNERS content for review.
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
OWNERSHIP_FILE="$(pwd)/config/repo-ownership.yml"

SKIPPED=0
UPDATED=0
DRY_RUN_COUNT=0
FAILURES=()        # clone/push/API errors
MISSING=()         # repos in target list with no entry in repo-ownership.yml
WRITE_WARNINGS=()  # repos where the discipline team lacks write access
# Associative array: repo → discipline team slug; loaded from OWNERSHIP_FILE.
# Initialised with =() so bash considers it 'set' under set -u.
declare -A REPO_OWNER=()

if [ ! -f "$REPO_FILE" ]; then
  echo "::error::Repo list file not found: $REPO_FILE"
  exit 1
fi

git config --global user.name  "bhom-devops[bot]"
git config --global user.email "bhom-devops[bot]@users.noreply.github.com"
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Loads REPO_OWNER from OWNERSHIP_FILE using yq to parse the team-grouped YAML.
# Fails immediately if a repo appears under more than one team (duplicate detection).
load_ownership_map() {
  echo "Loading ownership map from ${OWNERSHIP_FILE}..."
  while IFS=$'\t' read -r team repo; do
    [ -z "$repo" ] && continue
    if [[ -v REPO_OWNER["$repo"] ]]; then
      echo "::error::Duplicate entry in config/repo-ownership.yml — '$repo' is listed under both '${REPO_OWNER[$repo]}' and '$team'. Each repo must appear exactly once."
      exit 1
    fi
    REPO_OWNER["$repo"]="$team"
  done < <(yq eval '.teams | to_entries | .[] | .key as $team | .value[] | [$team, .] | @tsv' "$OWNERSHIP_FILE")
  echo "Loaded ${#REPO_OWNER[@]} repo ownership entries."
}

# Validates that every team slug in the ownership map exists as a GitHub org team.
# Fails immediately if any slug is invalid — a typo produces an unenforceable CODEOWNERS entry.
validate_team_slugs() {
  echo "Validating team slugs against GitHub org..."
  local invalid=0
  declare -A seen=()
  for slug in "${REPO_OWNER[@]}"; do
    seen["$slug"]=1
  done
  for slug in "${!seen[@]}"; do
    if ! gh api "orgs/${ORG}/teams/${slug}" > /dev/null 2>&1; then
      echo "::error::Team '${slug}' is listed in config/repo-ownership.yml but does not exist in the GitHub org. Fix the slug before re-running."
      invalid=$((invalid + 1))
    fi
  done
  if [ "$invalid" -gt 0 ]; then
    echo "::error::${invalid} invalid team slug(s) found in config/repo-ownership.yml. Correct them before re-running."
    exit 1
  fi
  echo "All team slugs verified."
}

# Returns 0 (success) if $1 team has write (push) or higher access to $2 repo.
# Uses GET /orgs/{org}/teams/{slug}/repos/{owner}/{repo} — covered by Members: Read.
check_team_write_access() {
  local team="$1" repo="$2"
  local has_write
  has_write=$(gh api "orgs/${ORG}/teams/${team}/repos/${ORG}/${repo}" \
    --jq '.permissions.push' 2>/dev/null || echo "false")
  [ "$has_write" = "true" ]
}

# Generates the expected CODEOWNERS content for a repo.
# Platform-owned repos get a single-line file; all others get the two-tier layout.
generate_codeowners() {
  local repo="$1"
  local team="$2"

  echo "# CODEOWNERS — managed by sync-codeowners workflow, do not edit manually."
  echo "# To change ownership, update config/repo-ownership.yml in DevOps_Toolkit and re-run the workflow."
  echo ""
  if [ "$team" = "$PLATFORM_TEAM" ]; then
    echo "# Platform team owns this repository in its entirety."
    echo "* @${ORG}/${PLATFORM_TEAM}"
  else
    echo "# Discipline team owns all source code."
    echo "* @${ORG}/${team}"
    echo ""
    echo "# Platform team owns all governance, CI configuration, and centrally managed files."
    echo "/.github/           @${ORG}/${PLATFORM_TEAM}"
    echo "/.editorconfig      @${ORG}/${PLATFORM_TEAM}"
    echo "/.gitattributes     @${ORG}/${PLATFORM_TEAM}"
    echo "/Directory.Build.props @${ORG}/${PLATFORM_TEAM}"
    echo "/LICENSE            @${ORG}/${PLATFORM_TEAM}"
  fi
}

mkdir -p targets

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -f "$OWNERSHIP_FILE" ]; then
  echo "::error::Ownership map not found at ${OWNERSHIP_FILE}."
  echo "::error::Create config/repo-ownership.yml in DevOps_Toolkit before running this workflow."
  exit 1
fi

# Verify the App token can query team→repo access (Members: Read).
# Required by check_team_write_access (GET /orgs/{org}/teams/{slug}/repos/{owner}/{repo}).
echo "Checking App token has permission to query org teams..."
if ! gh api "orgs/${ORG}/teams" --paginate > /dev/null 2>&1; then
  echo "::error::The App token cannot list org teams (GET /orgs/{org}/teams)."
  echo "::error::Confirm 'Organisation > Members: Read' is granted to the GitHub App installation."
  exit 1
fi
echo "Permission check passed."

load_ownership_map
validate_team_slugs

# ── Main loop ─────────────────────────────────────────────────────────────────

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "::group::$ORG/$repo"

  # Resolve discipline team from the ownership map.
  if [[ ! -v REPO_OWNER["$repo"] ]]; then
    echo "::warning::$repo has no entry in config/repo-ownership.yml — skipped. Add the discipline team to the map and re-run."
    MISSING+=("$repo")
    echo "::endgroup::"
    continue
  fi

  DISCIPLINE_TEAM="${REPO_OWNER[$repo]}"

  # Cross-check: the named team must have write (or higher) access, otherwise
  # GitHub silently ignores the team in CODEOWNERS even if the slug is correct.
  if ! check_team_write_access "$DISCIPLINE_TEAM" "$repo"; then
    echo "::warning::$repo — '@${ORG}/${DISCIPLINE_TEAM}' does not have write (or higher) access. CODEOWNERS will not be enforced by GitHub until the team is assigned with at least write access."
    WRITE_WARNINGS+=("$repo (@${ORG}/${DISCIPLINE_TEAM})")
  fi

  EXPECTED="$(generate_codeowners "$repo" "$DISCIPLINE_TEAM")"

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

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::[dry run] $repo would be updated. Discipline team: ${DISCIPLINE_TEAM}"
    echo "--- Expected CODEOWNERS for $repo ---"
    echo "$EXPECTED"
    echo "--- End ---"
    DRY_RUN_COUNT=$((DRY_RUN_COUNT + 1))
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

    # --force is safe: this branch is exclusively owned by this workflow.
    # Force-pushing also invalidates stale approvals on same-day re-runs
    # where team assignments may have changed since the last push.
    git push origin "$BRANCH" --force

    # Close any stale PRs from older datestamped branches.
    gh pr list \
      --repo "$ORG/$repo" \
      --state open \
      --json number,headRefName \
      --jq ".[] | select(.headRefName | startswith(\"${BRANCH_PREFIX}\")) | select(.headRefName != \"${BRANCH}\") | .number" \
    | xargs -r -I{} gh pr close {} --repo "$ORG/$repo" --comment "Superseded by a newer sync run."

    # Open a PR if one doesn't already exist — a new commit on the existing
    # branch is sufficient to update an open PR; no need to recreate it.
    if gh pr list \
        --repo "$ORG/$repo" \
        --state open \
        --head "$BRANCH" \
        --json number \
        --jq '.[0]' | grep -q .; then
      echo "::notice::Commit pushed to existing PR."
    else
      PR_URL=$(gh pr create \
        --repo "$ORG/$repo" \
        --head "$BRANCH" \
        --base develop \
        --title "chore: sync CODEOWNERS from team assignments" \
        --body "Automated update of \`.github/CODEOWNERS\` to reflect current GitHub team assignments.

**Discipline team:** \`@${ORG}/${DISCIPLINE_TEAM}\`

Ownership is declared in [\`config/repo-ownership.yml\`](https://github.com/${ORG}/DevOps_Toolkit/blob/main/config/repo-ownership.yml) in DevOps_Toolkit. This PR was opened by the [Sync CODEOWNERS](https://github.com/${ORG}/DevOps_Toolkit/actions/workflows/governance-sync-codeowners.yml) workflow. Review the diff and merge once confirmed.

> [!NOTE]
> The \`.github/\` folder is owned by \`@${ORG}/${PLATFORM_TEAM}\` — platform team approval is required to merge.")
      echo "::notice::PR opened: $PR_URL"
    fi
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
    if [ "$DRY_RUN" = "true" ]; then
      echo "| Would be updated (dry run) | $DRY_RUN_COUNT |"
      echo "| Already up to date | $SKIPPED |"
      echo "| Missing from ownership map | ${#MISSING[@]} |"
    else
      echo "| PRs opened | $UPDATED |"
      echo "| Already up to date | $SKIPPED |"
      echo "| Missing from ownership map | ${#MISSING[@]} |"
      echo "| Failed | ${#FAILURES[@]} |"
    fi

    if [ "${#MISSING[@]}" -gt 0 ]; then
      echo ""
      echo "**Repos missing from \`config/repo-ownership.yml\`** — add a discipline team and re-run:"
      for r in "${MISSING[@]}"; do
        echo "- \`$r\`"
      done
    fi

    if [ "${#WRITE_WARNINGS[@]}" -gt 0 ]; then
      echo ""
      echo "**Write-access warnings** — CODEOWNERS will not be enforced until resolved:"
      for r in "${WRITE_WARNINGS[@]}"; do
        echo "- \`$r\`"
      done
    fi

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

if [ "$DRY_RUN" = "true" ]; then
  echo "::notice::Sync complete (dry run). Would update: $DRY_RUN_COUNT  Already up to date: $SKIPPED  Missing from map: ${#MISSING[@]}"
else
  echo "::notice::Sync complete. PRs opened: $UPDATED  Skipped: $SKIPPED  Missing from map: ${#MISSING[@]}"
fi
