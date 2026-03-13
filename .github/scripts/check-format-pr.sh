#!/usr/bin/env bash
# check-format-pr.sh
#
# Runs dotnet format --verify-no-changes only for C# files changed in the PR.
# Expects to run from the caller repo root with changed_cs_files.txt in the current directory.
# Reports issues as warnings (exits 0 so the job does not fail).
# No EditorConfig required — uses dotnet format defaults.
#
# Usage: bash check-format-pr.sh

set -e

if [ ! -f changed_cs_files.txt ]; then
  echo "::notice::changed_cs_files.txt not found — format check skipped."
  exit 0
fi

# Find owning .csproj for each changed file (walk up from file dir until we hit a .csproj).
declare -A project_files
while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(dirname "$file")
  csproj=""
  while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    found=$(find "$dir" -maxdepth 1 -name "*.csproj" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      csproj="$found"
      break
    fi
    dir=$(dirname "$dir")
  done
  if [ -n "$csproj" ]; then
    project_files["$csproj"]="${project_files[$csproj]:+${project_files[$csproj]} }$file"
  fi
done < changed_cs_files.txt

if [ ${#project_files[@]} -eq 0 ]; then
  echo "::notice::No .csproj found for any changed file — format check skipped."
  exit 0
fi

# Discover solution(s) and which .csproj paths are in them (normalize to forward slashes).
solution_projects=()
for sln in *.sln; do
  [ -f "$sln" ] || continue
  grep -oE '"[^"]*\.csproj"' "$sln" | tr -d '"' | sed 's|\\|/|g' | sort -u > _sln_projects.txt
  while IFS= read -r p; do
    [ -n "$p" ] && solution_projects+=("$p")
  done < _sln_projects.txt
  rm -f _sln_projects.txt
  break
done

any_failed=0

# Split: files in a solution project vs files in a project not in the solution.
solution_include=()
declare -A outside_solution
for csproj in "${!project_files[@]}"; do
  in_sln=""
  for sp in "${solution_projects[@]}"; do
    if [ "$csproj" = "$sp" ]; then in_sln=1; break; fi
  done
  if [ -n "$in_sln" ]; then
    for f in ${project_files[$csproj]}; do solution_include+=("$f"); done
  else
    outside_solution["$csproj"]="${project_files[$csproj]}"
  fi
done

# Run format against the solution for all changed files that belong to solution projects (emits full diagnostics).
if [ ${#solution_include[@]} -gt 0 ] && [ ${#solution_projects[@]} -gt 0 ]; then
  sln=$(ls *.sln 2>/dev/null | head -1)
  if [ -n "$sln" ]; then
    include_args=()
    for f in "${solution_include[@]}"; do include_args+=(--include "$f"); done
    echo "::group::dotnet format — $sln (solution; changed files in solution projects)"
    set +e
    dotnet format "$sln" --verify-no-changes --verbosity normal "${include_args[@]}"
    exitcode=$?
    set -e
    echo "::endgroup::"
    [ "$exitcode" -ne 0 ] && any_failed=1
  fi
fi

# Run format per project for changed files whose project is NOT in the solution (e.g. .ci test projects).
# Use repo-relative paths for --include so dotnet format actually checks the files and reports violations.
for csproj in "${!outside_solution[@]}"; do
  include_args=()
  for f in ${outside_solution[$csproj]}; do
    [ -n "$f" ] && include_args+=(--include "$f")
  done
  [ ${#include_args[@]} -eq 0 ] && continue
  echo "::group::dotnet format — $csproj (outside solution)"
  set +e
  dotnet format "$csproj" --verify-no-changes --verbosity normal "${include_args[@]}"
  exitcode=$?
  set -e
  echo "::endgroup::"
  [ "$exitcode" -ne 0 ] && any_failed=1
done

if [ "$any_failed" -ne 0 ]; then
  echo "::warning title=Format check::Some changed files have formatting issues. Run \`dotnet format\` locally (or fix the reported files) to align with defaults."
fi
exit 0
