#!/usr/bin/env bash
# check-format.sh [whitespace|full]
#
# Runs a format check against every .csproj that owns a changed C# file
# listed in changed_cs_files.txt. Mode:
#   whitespace — dotnet format whitespace --folder (no deps; fast).
#   full       — dotnet format (style + analyzers) in project mode; needs staged DLLs.
#
# Emits ::error file=<path>:: for violations. Exits non-zero if any project fails.
# Relies on: GITHUB_WORKSPACE (for relative paths in annotations).
#
# Usage: bash check-format.sh [whitespace|full]

set -euo pipefail

mode="${1:-full}"
if [ "$mode" != "whitespace" ] && [ "$mode" != "full" ]; then
  echo "Usage: $0 whitespace|full" >&2
  exit 1
fi

declare -A projects
failed=0
report_dir=".format-report"
norm_ws="${GITHUB_WORKSPACE//\\/\/}"
norm_ws="${norm_ws%/}"

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

  if [ "$mode" = "whitespace" ]; then
    # Whitespace-only: --folder mode, no workspace/reference loading.
    format_out=$(dotnet format whitespace --folder "$proj_dir" \
      --verify-no-changes \
      --verbosity normal \
      "${include_args[@]}" 2>&1) || failed=1
    echo "$format_out"

    # Folder mode emits: <path>(line,col): error WHITESPACE: ...
    echo "$format_out" \
      | grep "error WHITESPACE:" \
      | grep -oP "^.*\.cs(?=\()" \
      | sort -u \
      | while IFS= read -r filepath; do
          norm_path="${filepath//\\/\/}"
          rel_path="${norm_path#$norm_ws/}"
          echo "::error file=$rel_path::Whitespace violation — run 'dotnet format' locally to fix."
        done || true
  else
    # Full: project mode, style + analyzers; requires staged assemblies.
    rm -rf "$report_dir"
    mkdir -p "$report_dir"
    format_out=$(dotnet format "$csproj" \
      --verify-no-changes \
      --verbosity normal \
      --report "$report_dir" \
      "${include_args[@]}" 2>&1) || failed=1
    echo "$format_out"

    report_file=$(find "$report_dir" -maxdepth 1 -name "*.json" 2>/dev/null | head -1)
    if [ -n "$report_file" ] && [ -f "$report_file" ]; then
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
  fi

  echo "::endgroup::"
done

if [ $failed -ne 0 ]; then
  echo "::error::One or more files have formatting violations. Run 'dotnet format' locally to fix."
fi

exit $failed
