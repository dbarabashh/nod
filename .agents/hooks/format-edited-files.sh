#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"
repo_root="$(git rev-parse --show-toplevel)"

while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    /*) path="$file" ;;
    *) path="$repo_root/$file" ;;
  esac
  [ -f "$path" ] || continue
  path="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  case "$path" in
    "$repo_root"/*) ;;
    *) continue ;;
  esac
  case "$path" in
    *.swift) command -v swiftformat >/dev/null && swiftformat "$path" --quiet || true ;;
  esac
done < <(
  jq -r '
    .tool_input as $input
    | (
        $input.file_path?,
        $input.files?[]?.file_path?,
        ($input.command? // ""
          | scan("(?m)^\\*\\*\\* (?:Add|Update) File: ([^\\r\\n]+)$")
          | .[0])
      )
    | select(type == "string" and length > 0)
  ' <<<"$payload"
)
