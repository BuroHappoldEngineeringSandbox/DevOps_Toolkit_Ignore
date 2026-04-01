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
# Team membership is fully dynamic — the script builds a repo→teams map by
# querying each team's repo list (GET /orgs/{org}/teams/{slug}/repos), which
# requires only Organisation > Members: Read. This avoids GET /repos/{org}/{repo}/teams
# which additionally requires Repository Administration read.
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
# Associative array: repo → space-separated sorted team slugs; built by build_repo_teams_map().
# Initialised with =() so bash considers it 'set' under set -u.
declare -A REPO_TEAMS=()

if [ ! -f "$REPO_FILE" ]; then
  echo "::error::Repo list file not found: $REPO_FILE"
  exit 1
fi

git config --global user.name  "bhom-devops[bot]"
git config --global user.email "bhom-devops[bot]@users.noreply.github.com"
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Builds REPO_TEAMS by iterating every org team (except platform) and recording
# which repos each team has access to. Uses GET /orgs/{org}/teams and
# GET /orgs/{org}/teams/{slug}/repos — both covered by Members: Read.
build_repo_teams_map() {
  echo "Fetching org teams..."
  local all_teams
  if ! all_teams=$(gh api "orgs/${ORG}/teams" --paginate \
    --jq "[.[] | .slug] | map(select(. != \"${PLATFORM_TEAM}\")) | .[]" 2>&1); then
    echo "::error::Failed to list org teams: ${all_teams}"
    exit 1
  fi

  local team_count=0
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    team_count=$((team_count + 1))
    local repos
    repos=$(gh api "orgs/${ORG}/teams/${slug}/repos" --paginate \
      --jq '.[].name' 2>/dev/null || true)
    while IFS= read -r repo_name; do
      [ -z "$repo_name" ] && continue
      if [[ -v REPO_TEAMS["$repo_name"] ]]; then
        # Key exists — append and re-sort.
        REPO_TEAMS[$repo_name]=$(printf '%s\n%s' "${REPO_TEAMS[$repo_name]}" "$slug" | sort | tr '\n' ' ' | sed 's/ $//')
      else
        REPO_TEAMS[$repo_name]="$slug"
      fi
    done <<< "$repos"
  done <<< "$all_teams"

  echo "Map built from ${team_count} team(s) covering ${#REPO_TEAMS[@]} repo(s)."
}

# Returns sorted team slugs for $1 from the pre-built REPO_TEAMS map.
get_product_teams() {
  local repo="$1"
  if [[ -v REPO_TEAMS["$repo"] ]]; then
    echo "${REPO_TEAMS[$repo]}" | tr ' ' '\n' | grep -v '^$' | sort
  fi
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
  echo "# Platform team owns all governance, CI configuration, and centrally managed files."
  echo "/.github/      @${ORG}/${PLATFORM_TEAM}"
  echo "/.editorconfig @${ORG}/${PLATFORM_TEAM}"
}

mkdir -p targets

# ── Preflight: verify the App token can query org teams ──────────────────────
# Uses GET /orgs/{org}/teams which requires Organisation > Members: Read.
# Fail fast here rather than silently mishandling 403s across every repo.
echo "Checking App token has permission to query org teams..."
if ! gh api "orgs/${ORG}/teams" --paginate > /dev/null 2>&1; then
  echo "::error::The App token cannot list org teams (GET /orgs/{org}/teams)."
  echo "::error::Confirm 'Organisation > Members: Read' is granted to the GitHub App installation."
  exit 1
fi
echo "Permission check passed."

build_repo_teams_map

# ── Main loop ─────────────────────────────────────────────────────────────────

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "::group::$ORG/$repo"

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
    TEAM_LIST="${ASSIGNED_TEAMS[*]:-none}"
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

**Assigned product team(s):** \`${TEAM_LIST}\`

This PR was opened by the [Sync CODEOWNERS](https://github.com/${ORG}/DevOps_Toolkit/actions/workflows/sync-codeowners.yml) workflow. Review the diff and merge once the team assignments are settled.

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
