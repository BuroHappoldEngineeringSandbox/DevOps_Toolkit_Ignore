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

# 1. All required keys exist.
for state in "${POLICY_STATES[@]}"; do
  for key in "${POLICY_KEYS[@]}"; do
    if ! jq -e --arg s "$state" --arg k "$key" \
      '(.[$s] | type == "object") and (.[$s] | has($k))' "$POLICY" >/dev/null; then
      echo "::error::policy.json missing required key: $state.$key"
      exit 1
    fi
  done
done

# 2. Boolean keys must contain actual JSON booleans (not strings, not null).
for state in "${POLICY_STATES[@]}"; do
  for key in "${POLICY_BOOL_KEYS[@]}"; do
    if ! jq -e --arg s "$state" --arg k "$key" \
      '.[$s][$k] | type == "boolean"' "$POLICY" >/dev/null; then
      echo "::error::policy.json $state.$key must be a boolean (true or false), got: $(jq -r --arg s "$state" --arg k "$key" '.[$s][$k]' "$POLICY")"
      exit 1
    fi
  done
done

# 3. compliance_checks must be a well-formed array of known tokens.
#    When compliance is enabled for a state, the array must also be non-empty.
for state in "${POLICY_STATES[@]}"; do
  if ! jq -e --arg s "$state" '.[$s].compliance_checks | type == "array"' "$POLICY" >/dev/null; then
    echo "::error::policy.json $state.compliance_checks must be a JSON array."
    exit 1
  fi

  # When compliance is enabled, an empty array would cause the runner to be invoked
  # with no checks — silently exiting 0, looking like a pass.
  compliance_enabled=$(jq -r --arg s "$state" '.[$s].compliance' "$POLICY")
  if [ "$compliance_enabled" = "true" ]; then
    if ! jq -e --arg s "$state" '.[$s].compliance_checks | length > 0' "$POLICY" >/dev/null; then
      echo "::error::policy.json $state.compliance_checks must be non-empty when compliance is true."
      exit 1
    fi
  fi

  # Build a jq-safe set of valid tokens from POLICY_COMPLIANCE_CHECK_TOKENS.
  valid_tokens_json=$(printf '%s\n' "${POLICY_COMPLIANCE_CHECK_TOKENS[@]}" | jq -R . | jq -s .)

  invalid=$(jq -r --arg s "$state" --argjson valid "$valid_tokens_json" \
    '.[$s].compliance_checks - $valid | .[]' "$POLICY")
  if [ -n "$invalid" ]; then
    echo "::error::policy.json $state.compliance_checks contains unknown token(s): $invalid"
    echo "::error::Valid tokens: ${POLICY_COMPLIANCE_CHECK_TOKENS[*]}"
    exit 1
  fi
done

echo "::notice::policy.json is valid"
