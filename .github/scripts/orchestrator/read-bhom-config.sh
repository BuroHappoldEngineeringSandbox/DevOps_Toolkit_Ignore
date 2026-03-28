#!/usr/bin/env bash
# Reads caller-repo overrides from .github/bhom.json.
# configuration is NOT caller-configurable; it is locked to Release by the orchestrator
# (with a DevOps-only override via the `configuration` workflow_call input).
set -euo pipefail

BHOM="${BHOM_PATH:-.github/bhom.json}"
DOTNET_VERSION="8.0"
TEST_SOLUTION=".ci/tests/unitTests/UnitTests.sln"

if [ ! -f "$BHOM" ]; then
  echo "::notice::No bhom.json found — using defaults"
else
  # Warn if a caller repo still has the legacy 'configuration' key.
  # configuration has been locked to Release since DevOps_Toolkit v2 and is no longer
  # caller-configurable. Remove this key from your bhom.json.
  if jq -e 'has("configuration")' "$BHOM" >/dev/null 2>&1; then
    echo "::warning::bhom.json contains a 'configuration' key which is no longer supported. Configuration is locked to Release by the orchestrator. Remove this key from your .github/bhom.json."
  fi

  _DOTNET=$(jq -r '.dotnet_version // empty' "$BHOM")
  _SOLUTION=$(jq -r '.unit_tests.solution // empty' "$BHOM")

  # Validate dotnet_version format if provided (e.g. 8.0, 9.x).
  if [ -n "$_DOTNET" ]; then
    if ! echo "$_DOTNET" | grep -qE '^[0-9]+\.[0-9x]+$'; then
      echo "::error::Invalid dotnet_version '$_DOTNET' in bhom.json. Expected format: e.g. 8.0 or 8.x"
      exit 1
    fi
    # Enforce minimum supported version (8.0).
    _MAJOR=$(echo "$_DOTNET" | cut -d. -f1)
    if [ "$_MAJOR" -lt 8 ]; then
      echo "::error::dotnet_version '$_DOTNET' is below the minimum supported version (8.0)."
      exit 1
    fi
  fi

  DOTNET_VERSION=${_DOTNET:-$DOTNET_VERSION}
  TEST_SOLUTION=${_SOLUTION:-$TEST_SOLUTION}
fi

{
  echo "dotnet_version=$DOTNET_VERSION"
  echo "test_solution=$TEST_SOLUTION"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::dotnet_version=$DOTNET_VERSION"
echo "::notice::test_solution=$TEST_SOLUTION"
