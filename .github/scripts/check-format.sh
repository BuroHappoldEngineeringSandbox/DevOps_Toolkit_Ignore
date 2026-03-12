#!/usr/bin/env bash
# check-format.sh
#
# Runs full dotnet format (whitespace + style + analyzers) in project mode
# against every .csproj that owns a changed C# file listed in changed_cs_files.txt.
# Requires BHoM dependency assemblies to be staged (done by the format job).
#
# Emits ::error file=<path>:: annotations so violations appear inline in the
# PR diff. Exits non-zero if any project has formatting violations.
#
# Relies on: GITHUB_WORKSPACE (repo root, for relative paths in annotations).
#
# Usage: bash .github/scripts/check-format.sh

set -euo pipefail

declare -A projects
failed=0
report_dir=".format-report"

# Walk up the directory tree from each changed file to find its owning .csproj.
while IFS= read -r file; do
  dir=$(dirname "$file")
  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    csproj=$(find "$dir" -maxdepth 1 -name "*.csproj" | head -1)
    if [ -n "$csproj" ]; then
      projects["$csproj"]=1
      break
    fi
    dir=$(dirname "$dir")
  done
done < changed_cs_files.txt

if [ ${#projects[@]} -eq 0 ]; then
  echo "::notice::No .csproj found for any changed file — format check skipped."
  exit 0
fi

for csproj in "${!projects[@]}"; do
  echo "::group::dotnet format — $csproj"
  proj_dir=$(dirname "$csproj")

  # Build --include as an array so paths with spaces are handled correctly.
  # Paths must be relative to the project directory, not the repo root.
  include_args=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && include_args+=(--include "$f")
  done < <(
    if [ "$proj_dir" = "." ]; then
      cat changed_cs_files.txt
    else
      grep "^${proj_dir}/" changed_cs_files.txt | sed "s|^${proj_dir}/||"
    fi
  )

  if [ ${#include_args[@]} -eq 0 ]; then
    echo "No changed files belong to this project — skipping."
    echo "::endgroup::"
    continue
  fi

  # Full dotnet format (project mode): whitespace + style + analyzers.
  # All tiers respect .editorconfig. Workspace must load (BHoM DLLs staged by job).
  # --report writes a JSON file into the given directory.
  rm -rf "$report_dir"
  mkdir -p "$report_dir"
  format_out=$(dotnet format "$csproj" \
    --verify-no-changes \
    --verbosity normal \
    --report "$report_dir" \
    "${include_args[@]}" 2>&1) || failed=1

  echo "$format_out"

  # Parse the JSON report for file paths; emit one ::error per file.
  # Paths in the report are absolute; normalize and strip workspace for annotations.
  report_file=$(find "$report_dir" -maxdepth 1 -name "*.json" 2>/dev/null | head -1)
  if [ -n "$report_file" ] && [ -f "$report_file" ]; then
    norm_ws="${GITHUB_WORKSPACE//\\/\/}"
    norm_ws="${norm_ws%/}"
    while IFS= read -r filepath; do
      [ -z "$filepath" ] && continue
      norm_path="${filepath//\\/\/}"
      rel_path="${norm_path#$norm_ws/}"
      echo "::error file=$rel_path::Formatting violation — run 'dotnet format' locally to fix."
    done < <(python -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for item in data:
        if isinstance(item, dict) and 'FilePath' in item:
            print(item['FilePath'])
except (FileNotFoundError, json.JSONDecodeError):
    pass
" "$report_file" 2>/dev/null || true)
  fi

  echo "::endgroup::"
done

if [ $failed -ne 0 ]; then
  echo "::error::One or more files have formatting violations. Run 'dotnet format' locally to fix."
fi

exit $failed
