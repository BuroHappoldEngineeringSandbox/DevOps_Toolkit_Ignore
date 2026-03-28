#!/usr/bin/env bash
# Writes all locked pipeline settings to GITHUB_OUTPUT.
# All values are centrally owned — update here to roll changes across the org.
set -euo pipefail

# All BHoM repos target netstandard2.0; SDK version has no effect on build output.
DOTNET_VERSION="8.0"
CONFIGURATION="Release"
TEST_SOLUTION=".ci/tests/unitTests/UnitTests.sln"

# Warn if a caller repo still has a bhom.json — it is no longer read.
BHOM="${BHOM_PATH:-.github/bhom.json}"
if [ -f "$BHOM" ]; then
  echo "::warning::This repo has a .github/bhom.json which is no longer read. All pipeline settings are locked centrally in DevOps_Toolkit. The file can be safely deleted."
fi

{
  echo "dotnet_version=$DOTNET_VERSION"
  echo "configuration=$CONFIGURATION"
  echo "test_solution=$TEST_SOLUTION"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::dotnet_version=$DOTNET_VERSION  configuration=$CONFIGURATION  test_solution=$TEST_SOLUTION"
