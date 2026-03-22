#!/usr/bin/env bash
# Resolves BHoM CI stage from GitHub repo topics and writes job outputs from
# .github/config/bhom-stage-matrix.json (single source of truth).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX="$ROOT/.github/config/bhom-stage-matrix.json"

if [[ ! -f "$MATRIX" ]]; then
  echo "::error::Missing stage matrix: $MATRIX"
  exit 1
fi

json=$(gh api "repos/${GITHUB_REPOSITORY}/topics" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28")

echo "::notice::Repository topics: $(echo "$json" | jq -r '.names | join(" ") | if . == "" then "<none>" else . end')"

stage=""
while IFS= read -r topic; do
  if echo "$json" | jq -e --arg t "$topic" '.names | index($t)' >/dev/null; then
    stage="$topic"
    break
  fi
done < <(jq -r '.topic_priority[]' "$MATRIX")

if [[ -z "$stage" ]]; then
  echo "::error::Add one repository topic: bhom-prototype, bhom-alpha, or bhom-beta (Repository → Settings → General → Topics)."
  exit 1
fi

if ! jq -e --arg s "$stage" '.stages | has($s)' "$MATRIX" >/dev/null; then
  echo "::error::Stage '$stage' is not defined in bhom-stage-matrix.json"
  exit 1
fi

echo "stage=$stage" >> "$GITHUB_OUTPUT"

# Merge shared defaults with stage-specific settings; emit key=value lines for GITHUB_OUTPUT.
jq -r --arg s "$stage" '
  .defaults * .stages[$s]
  | to_entries[]
  | "\(.key)=\(.value | tostring)"
' "$MATRIX" >> "$GITHUB_OUTPUT"

echo "::notice title=BHoM stage::Resolved stage: $stage"
