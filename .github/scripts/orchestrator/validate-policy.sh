#!/usr/bin/env bash
# Validate policy.json structure (invoked from ci-orchestrator after _central checkout).
set -euo pipefail

POLICY="${POLICY_PATH:-_central/policy.json}"

if [ ! -f "$POLICY" ]; then
  echo "::error::policy.json not found at repo root of the policy checkout (DevOps_Toolkit)."
  exit 1
fi

# validate all required keys exist (use has(); jq's // treats false as missing)
for state in prototype alpha beta; do
  for key in format compliance compliance_checks dataset build unit-tests; do
    if ! jq -e --arg s "$state" --arg k "$key" \
      '(.[$s] | type == "object") and (.[$s] | has($k))' "$POLICY" >/dev/null; then
      echo "::error::policy.json missing required key: $state.$key"
      exit 1
    fi
  done
done

echo "::notice::policy.json is valid"
