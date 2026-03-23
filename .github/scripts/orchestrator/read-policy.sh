#!/usr/bin/env bash
# Read policy for STATE and write job outputs; optional bhom.json compliance override.
set -euo pipefail

POLICY="${POLICY_PATH:-_central/policy.json}"
STATE="${STATE:?STATE must be set (repo topic: prototype | alpha | beta)}"

if ! jq -e --arg s "$STATE" 'has($s) and (.[$s] | type == "object")' "$POLICY" >/dev/null; then
  echo "::error::policy.json has no policy block for state '$STATE'."
  exit 1
fi

RUN_FORMAT=$(jq -r --arg s "$STATE" '.[$s].format' "$POLICY")
RUN_COMPLIANCE=$(jq -r --arg s "$STATE" '.[$s].compliance' "$POLICY")
COMPLIANCE_CHECKS=$(jq -r --arg s "$STATE" '.[$s].compliance_checks' "$POLICY")
RUN_DATASET=$(jq -r --arg s "$STATE" '.[$s].dataset' "$POLICY")
RUN_BUILD=$(jq -r --arg s "$STATE" '.[$s].build' "$POLICY")
RUN_UNIT_TESTS=$(jq -r --arg s "$STATE" '.[$s]["unit-tests"]' "$POLICY")

if [ "$COMPLIANCE_CHECKS" = "null" ]; then
  echo "::error::policy.json produced null for compliance_checks (state=$STATE)."
  exit 1
fi

# Catch jq "null" / missing paths if validation and read ever diverge
for name val in \
  run_format "$RUN_FORMAT" \
  run_compliance "$RUN_COMPLIANCE" \
  run_dataset "$RUN_DATASET" \
  run_build "$RUN_BUILD" \
  run_unit_tests "$RUN_UNIT_TESTS"; do
  if [ "$val" = "null" ]; then
    echo "::error::policy.json produced null for $name (state=$STATE)."
    exit 1
  fi
done

BHOM="${BHOM_PATH:-.github/bhom.json}"
if [ -f "$BHOM" ]; then
  OVERRIDE=$(jq -r '.compliance.checks // empty' "$BHOM")
  if [ -n "$OVERRIDE" ]; then
    VALID="project code copyright documentation"
    # shellcheck disable=SC2086
    for check in $OVERRIDE; do
      if ! echo "$VALID" | grep -qw "$check"; then
        echo "::error::Invalid compliance check in bhom.json: '$check'. Valid values: $VALID"
        exit 1
      fi
    done
    COMPLIANCE_CHECKS="$OVERRIDE"
    echo "::notice::Compliance checks overridden by bhom.json: $COMPLIANCE_CHECKS"
  fi
fi

{
  echo "run_format=$RUN_FORMAT"
  echo "run_compliance=$RUN_COMPLIANCE"
  echo "compliance_checks=$COMPLIANCE_CHECKS"
  echo "run_dataset=$RUN_DATASET"
  echo "run_build=$RUN_BUILD"
  echo "run_unit_tests=$RUN_UNIT_TESTS"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::run_format=$RUN_FORMAT"
echo "::notice::run_compliance=$RUN_COMPLIANCE"
echo "::notice::compliance_checks=$COMPLIANCE_CHECKS"
echo "::notice::run_dataset=$RUN_DATASET"
echo "::notice::run_build=$RUN_BUILD"
echo "::notice::run_unit_tests=$RUN_UNIT_TESTS"
