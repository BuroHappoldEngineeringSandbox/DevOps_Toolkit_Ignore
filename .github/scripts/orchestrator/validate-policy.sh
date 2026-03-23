#!/usr/bin/env bash
# Validate policy.json structure (invoked from ci-orchestrator after _central checkout).
set -euo pipefail

POLICY="${POLICY_PATH:-_central/policy.json}"

if [ ! -f "$POLICY" ]; then
  echo "::error::policy.json not found at repo root of the policy checkout (DevOps_Toolkit)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=policy-contract.sh
source "${SCRIPT_DIR}/policy-contract.sh"

# validate all required keys exist (use has(); jq's // treats false as missing)
for state in "${POLICY_STATES[@]}"; do
  for key in "${POLICY_KEYS[@]}"; do
    if ! jq -e --arg s "$state" --arg k "$key" \
      '(.[$s] | type == "object") and (.[$s] | has($k))' "$POLICY" >/dev/null; then
      echo "::error::policy.json missing required key: $state.$key"
      exit 1
    fi
  done
done

echo "::notice::policy.json is valid"
