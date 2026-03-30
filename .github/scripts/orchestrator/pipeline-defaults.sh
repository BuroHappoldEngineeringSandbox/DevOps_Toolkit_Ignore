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
#                    Always Release for CI builds.
#                    Note: unit-test solutions may define a 'Test'
#                    MSBuild configuration (disables post-build xcopy
#                    events for local dev). On CI no assemblies are
#                    locked by UIs, so Release is safe and avoids
#                    requiring every repo to define a 'Test' config.
#
#   TEST_SOLUTION    Not defined here — the conventional path
#                    .ci/unit-tests/<RepoName>_Tests.sln is
#                    repo-specific. ci-unit-tests.yml discovers
#                    the solution dynamically at runtime.
# ============================================================
set -euo pipefail

DOTNET_VERSION="8.0"
CONFIGURATION="Release"

{
  echo "dotnet_version=$DOTNET_VERSION"
  echo "configuration=$CONFIGURATION"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

echo "::notice::dotnet_version=$DOTNET_VERSION  configuration=$CONFIGURATION"
