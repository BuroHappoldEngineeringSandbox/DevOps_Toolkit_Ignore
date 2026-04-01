#!/usr/bin/env bash
# Syncs bhom-team-<slug> topics on BHoM repos from live GitHub team-repo
# assignments.
#
# Usage: sync-repo-topics.sh <repo-list-file>
#
# Environment variables (set by the calling workflow):
#   GH_TOKEN         — installation token for the DevOps GitHub App
#   ORG              — GitHub organisation login
#   DRY_RUN          — 'true' to log intended changes without updating topics
#   DISCIPLINE_TEAMS — space-separated list of discipline team slugs to consider
#                      (default: bim data-and-ai specialist-consulting structures
#                                sustainability-physics prototypes)
#
# Only topics prefixed with "bhom-team-" are managed. All other topics on a
# repo (e.g. bhom-beta, bhom-alpha) are preserved exactly as-is.
#
# A repo gains bhom-team-<slug> for each discipline team that has write
# (push), maintain, or admin access on it. Platform and per-repo teams are
# not in DISCIPLINE_TEAMS, so they never generate a topic.
#
# Failures are collected and reported at the end without stopping the loop.
set -euo pipefail

REPO_FILE="${1:?Usage: sync-repo-topics.sh <repo-list-file>}"
DRY_RUN="${DRY_RUN:-false}"
ORG="${ORG:?ORG must be set}"
DISCIPLINE_TEAMS="${DISCIPLINE_TEAMS:-bim data-and-ai specialist-consulting structures sustainability-physics prototypes}"
TOPIC_PREFIX="bhom-team-"

SKIPPED=0
UPDATED=0
FAILURES=()
# Associative array: repo name → space-separated sorted discipline team slugs
# that have write-or-above access. Populated by build_repo_teams_map().
declare -A REPO_TEAMS=()

if [ ! -f "$REPO_FILE" ]; then
  echo "::error::Repo list file not found: $REPO_FILE"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns 0 if $1 is in DISCIPLINE_TEAMS, 1 otherwise.
is_discipline_team() {
  local slug="$1"
  for t in $DISCIPLINE_TEAMS; do
    [ "$t" = "$slug" ] && return 0
  done
  return 1
}

# Builds REPO_TEAMS by iterating every org team, skipping non-discipline ones,
# and recording repos where each discipline team has push/maintain/admin access.
# Uses GET /orgs/{org}/teams and GET /orgs/{org}/teams/{slug}/repos —
# both covered by Organisation > Members: Read.
build_repo_teams_map() {
  echo "Fetching org teams..."
  local all_teams
  if ! all_teams=$(gh api "orgs/${ORG}/teams" --paginate \
    --jq '.[].slug' 2>&1); then
    echo "::error::Failed to list org teams: ${all_teams}"
    exit 1
  fi

  local team_count=0
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    is_discipline_team "$slug" || continue
    team_count=$((team_count + 1))
    echo "  Scanning team: $slug"

    local repos
    # Filter to repos where this team has at least write (push) permission.
    repos=$(gh api "orgs/${ORG}/teams/${slug}/repos" --paginate \
      --jq '.[] | select(.permissions.push or .permissions.maintain or .permissions.admin) | .name' \
      2>/dev/null || true)

    while IFS= read -r repo_name; do
      [ -z "$repo_name" ] && continue
      if [[ -v REPO_TEAMS["$repo_name"] ]]; then
        # Key exists — append slug and re-sort.
        REPO_TEAMS[$repo_name]=$(
          printf '%s\n%s' "${REPO_TEAMS[$repo_name]}" "$slug" \
          | sort | tr '\n' ' ' | sed 's/ $//'
        )
      else
        REPO_TEAMS[$repo_name]="$slug"
      fi
    done <<< "$repos"
  done <<< "$all_teams"

  echo "Map built from ${team_count} discipline team(s) covering ${#REPO_TEAMS[@]} repo(s)."
}

# Outputs sorted discipline team slugs assigned to $1, one per line.
get_discipline_teams_for_repo() {
  local repo="$1"
  if [[ -v REPO_TEAMS["$repo"] ]]; then
    echo "${REPO_TEAMS[$repo]}" | tr ' ' '\n' | grep -v '^$' | sort
  fi
}

# ── Preflight: verify the App token can query org teams ──────────────────────
echo "Checking App token has permission to query org teams..."
if ! gh api "orgs/${ORG}/teams" --paginate > /dev/null 2>&1; then
  echo "::error::Cannot list org teams (GET /orgs/{org}/teams)."
  echo "::error::Confirm 'Organisation > Members: Read' is granted to the GitHub App installation."
  exit 1
fi
echo "Permission check passed."

build_repo_teams_map

# ── Main loop ─────────────────────────────────────────────────────────────────

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  echo "::group::$ORG/$repo"

  # Fetch the repo's current full topic list as a JSON array.
  current_topics_json=$(gh api "repos/${ORG}/${repo}/topics" \
    --jq '.names' 2>/dev/null || echo '[]')

  # Current bhom-team-* topics as a sorted newline-delimited list.
  current_team_topics=$(echo "$current_topics_json" \
    | jq -r --arg p "$TOPIC_PREFIX" '.[] | select(startswith($p))' \
    | sort)

  # Desired bhom-team-* topics derived from live team assignments.
  mapfile -t assigned_teams < <(get_discipline_teams_for_repo "$repo")
  desired_team_topics=""
  if [ "${#assigned_teams[@]}" -gt 0 ]; then
    for slug in "${assigned_teams[@]}"; do
      [ -z "$slug" ] && continue
      desired_team_topics="${desired_team_topics}${TOPIC_PREFIX}${slug}"$'\n'
    done
  fi
  desired_team_topics=$(printf '%s' "$desired_team_topics" | sort | grep -v '^$' || true)

  # Skip if already correct.
  if [ "$current_team_topics" = "$desired_team_topics" ]; then
    echo "::notice::$repo topics already up to date — skipped."
    SKIPPED=$((SKIPPED + 1))
    echo "::endgroup::"
    continue
  fi

  # Diff for logging.
  ADDED=$(comm -23 \
    <(echo "$desired_team_topics") \
    <(echo "$current_team_topics") \
    | tr '\n' ' ' | sed 's/ $//')
  REMOVED=$(comm -23 \
    <(echo "$current_team_topics") \
    <(echo "$desired_team_topics") \
    | tr '\n' ' ' | sed 's/ $//')

  if [ "$DRY_RUN" = "true" ]; then
    [ -n "$ADDED"   ] && echo "::notice::[dry run] $repo  +add: $ADDED"
    [ -n "$REMOVED" ] && echo "::notice::[dry run] $repo  -remove: $REMOVED"
    echo "::endgroup::"
    continue
  fi

  # Build the replacement topic list: preserve non-bhom-team-* topics,
  # replace all bhom-team-* topics with the desired set.
  new_topics_json=$(
    {
      echo "$current_topics_json" \
        | jq -r --arg p "$TOPIC_PREFIX" '.[] | select(startswith($p) | not)'
      echo "$desired_team_topics"
    } \
    | grep -v '^$' \
    | sort \
    | jq -R . \
    | jq -s '{"names": .}'
  )

  if echo "$new_topics_json" \
      | gh api "repos/${ORG}/${repo}/topics" --method PUT --input - > /dev/null; then
    [ -n "$ADDED"   ] && echo "::notice::$repo  added: $ADDED"
    [ -n "$REMOVED" ] && echo "::notice::$repo  removed: $REMOVED"
    UPDATED=$((UPDATED + 1))
  else
    echo "::error::Failed to update topics for $repo"
    FAILURES+=("$repo")
  fi

  echo "::endgroup::"
done < "$REPO_FILE"

# ── Step summary ──────────────────────────────────────────────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Repo topic sync"
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
  echo "::error::Topic sync failed for ${#FAILURES[@]} repo(s): ${FAILURES[*]}"
  exit 1
fi

echo "::notice::Sync complete. Updated: $UPDATED  Skipped: $SKIPPED"
