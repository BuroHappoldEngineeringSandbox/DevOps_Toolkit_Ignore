#!/usr/bin/env bash
# check-format-pr.sh
#
# Runs dotnet format --verify-no-changes only for C# files changed in the PR.
# Expects to run from the caller repo root with changed_dotnet_files.txt in the current directory.
# Applies the canonical BHoM .editorconfig from DevOps_Toolkit/config/.editorconfig
# so that all repos are checked against the same rules regardless of their local .editorconfig.
#
# Severity behaviour:
#   error-level diagnostics  → job fails (PR is blocked)
#   warning-level diagnostics → job passes with a warning annotation
#   suggestion-level          → not reported
#
# Multi-solution repos: only the first path when *.sln names are sorted (LC_ALL=C) is used to
# discover which .csproj entries are “in solution” and as the dotnet format target for in-sln
# files. Other .sln files are ignored here — document or extend if you need full coverage.
#
# Usage: bash check-format-pr.sh

set -euo pipefail

# Apply canonical EditorConfig.
# TOOLKIT_DIR is the path where DevOps_Toolkit was checked out (default: _toolkit).
TOOLKIT_DIR="${TOOLKIT_DIR:-_toolkit}"
CANONICAL_EDITORCONFIG="$TOOLKIT_DIR/config/.editorconfig"

if [ -f "$CANONICAL_EDITORCONFIG" ]; then
  cp "$CANONICAL_EDITORCONFIG" .editorconfig
  echo "::notice::Canonical .editorconfig applied from $CANONICAL_EDITORCONFIG."
else
  echo "::warning::Canonical .editorconfig not found at $CANONICAL_EDITORCONFIG — using repo's own .editorconfig (if present)."
fi

if [ ! -f changed_dotnet_files.txt ]; then
  echo "::notice::changed_dotnet_files.txt not found — format check skipped."
  exit 0
fi

# Find owning .csproj for each changed file (walk up from file dir until we hit a .csproj).
# Store newline-separated paths per csproj so paths with spaces are safe to iterate.
declare -A project_files
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(dirname "$file")
  csproj=""
  while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    # shellcheck disable=SC2012
    found=$(find "$dir" -maxdepth 1 -name "*.csproj" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      csproj="$found"
      break
    fi
    dir=$(dirname "$dir")
  done
  if [ -n "$csproj" ]; then
    if [ -n "${project_files[$csproj]+x}" ]; then
      project_files["$csproj"]="${project_files[$csproj]}"$'\n'"$file"
    else
      project_files["$csproj"]="$file"
    fi
  fi
done < changed_dotnet_files.txt

if [ ${#project_files[@]} -eq 0 ]; then
  echo "::notice::No .csproj found for any changed file — format check skipped."
  exit 0
fi

# One primary .sln (deterministic): sorted basename order, first only. Parse listed .csproj paths
# (normalize to forward slashes for comparison with find output on Linux agents).
primary_sln=""
solution_projects=()
shopt -s nullglob
_slns=( *.sln )
shopt -u nullglob
if [ ${#_slns[@]} -gt 0 ]; then
  mapfile -t _sln_candidates < <(printf '%s\n' "${_slns[@]}" | LC_ALL=C sort)
  primary_sln="${_sln_candidates[0]}"
  set +o pipefail
  mapfile -t solution_projects < <(
    grep -oE '"[^"]*\.csproj"' "$primary_sln" 2>/dev/null | tr -d '"' | sed 's|\\|/|g' | sort -u
  )
  set -o pipefail
fi

any_errors=0
any_warnings=0

# run_check TARGET LABEL [--include FILE ...]
#
# Pass 1: --severity warn  — full diagnostic report for annotations
# Pass 2: --severity error — fast second pass only when pass 1 found violations,
#         to distinguish blocking errors from advisory warnings.
run_check() {
  local target="$1" label="$2"
  shift 2
  local include_args=("$@")

  echo "::group::dotnet format — $label"
  set +e
  dotnet format "$target" --verify-no-changes --verbosity diagnostic --severity warn "${include_args[@]}"
  local warn_exit=$?
  set -e
  echo "::endgroup::"

  if [ "$warn_exit" -ne 0 ]; then
    # Determine whether any violations are error-level (suppress output — already shown above).
    set +e
    dotnet format "$target" --verify-no-changes --severity error "${include_args[@]}" > /dev/null 2>&1
    local error_exit=$?
    set -e

    if [ "$error_exit" -ne 0 ]; then
      echo "::error::Error-severity format violations found in $label. Run \`dotnet format\` locally to fix."
      any_errors=1
    else
      echo "::warning::Format warnings found in $label. Run \`dotnet format\` locally to resolve."
      any_warnings=1
    fi
  fi
}

# Split: files in a solution project vs files in a project not listed in the primary .sln
# (e.g. .ci/tests — run format per .csproj).
solution_include=()
declare -A outside_solution
for csproj in "${!project_files[@]}"; do
  in_sln=""
  for sp in "${solution_projects[@]}"; do
    if [ "$csproj" = "$sp" ]; then in_sln=1; break; fi
  done
  if [ -n "$in_sln" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      solution_include+=("$f")
    done <<< "${project_files[$csproj]}"
  else
    outside_solution["$csproj"]="${project_files[$csproj]}"
  fi
done

# Run against the primary solution for changed files that belong to solution projects.
if [ ${#solution_include[@]} -gt 0 ] && [ ${#solution_projects[@]} -gt 0 ] && [ -n "$primary_sln" ]; then
  include_args=()
  for f in "${solution_include[@]}"; do include_args+=(--include "$f"); done
  run_check "$primary_sln" "$primary_sln (solution; changed files in solution projects)" "${include_args[@]}"
fi

# Run per project for changed files whose project is NOT in the primary solution.
for csproj in "${!outside_solution[@]}"; do
  include_args=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    include_args+=(--include "$f")
  done <<< "${outside_solution[$csproj]}"
  [ ${#include_args[@]} -eq 0 ] && continue
  run_check "$csproj" "$csproj (outside primary solution)" "${include_args[@]}"
done

if [ "$any_errors" -ne 0 ]; then
  echo "::error title=Format check::Error-severity format violations found. Run \`dotnet format\` locally to fix before merging."
  exit 1
elif [ "$any_warnings" -ne 0 ]; then
  echo "::warning title=Format check::Format warnings found. Run \`dotnet format\` locally to resolve."
fi
exit 0
