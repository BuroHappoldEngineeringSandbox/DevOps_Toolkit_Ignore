#!/usr/bin/env bash
# ============================================================
# Pipeline defaults — single source of truth for all BHoM CI
# settings. Update values here to roll changes across the org.
#
#   DOTNET_VERSION   .NET SDK version used to build and test.
#                    All BHoM repos target netstandard2.0;
#                    SDK version has no effect on build output.
#
#   CONFIGURATION    MSBuild/dotnet build configuration.
#                    Always Release for CI.
#
#   TEST_SOLUTION    Conventional path to the unit-test solution
#                    within a caller repo. The unit-tests job
#                    skips gracefully if the path does not exist.
# ============================================================
set -euo pipefail

DOTNET_VERSION="8.0"
CONFIGURATION="Release"
TEST_SOLUTION=".ci/tests/unitTests/UnitTests.sln"

{
  echo "dotnet_version=$DOTNET_VERSION"
  echo "configuration=$CONFIGURATION"
  echo "test_solution=$TEST_SOLUTION"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::dotnet_version=$DOTNET_VERSION  configuration=$CONFIGURATION  test_solution=$TEST_SOLUTION"
