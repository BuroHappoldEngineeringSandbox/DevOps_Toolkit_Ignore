#!/usr/bin/env bash
# Defaults and optional overrides from .github/bhom.json (caller repo).
set -euo pipefail

BHOM="${BHOM_PATH:-.github/bhom.json}"
DOTNET_VERSION="8.0"
CONFIGURATION="Release"
TEST_SOLUTION=""

if [ ! -f "$BHOM" ]; then
  echo "::notice::No bhom.json found - using orchestrator defaults"
else
  _DOTNET=$(jq -r '.dotnet_version // empty' "$BHOM")
  _CONFIG=$(jq -r '.configuration // empty' "$BHOM")
  _SOLUTION=$(jq -r '.unit_tests.solution // empty' "$BHOM")
  DOTNET_VERSION=${_DOTNET:-$DOTNET_VERSION}
  CONFIGURATION=${_CONFIG:-$CONFIGURATION}
  TEST_SOLUTION=${_SOLUTION:-$TEST_SOLUTION}
fi

{
  echo "dotnet_version=$DOTNET_VERSION"
  echo "configuration=$CONFIGURATION"
  echo "test_solution=$TEST_SOLUTION"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::dotnet_version=$DOTNET_VERSION"
echo "::notice::configuration=$CONFIGURATION"
echo "::notice::test_solution=${TEST_SOLUTION:-not set}"
