#!/usr/bin/env bash
set -euo pipefail

# Usage: ./find_error_selector.sh <target-selector> [search_dirs_comma_separated]
# Example: ./find_error_selector.sh 0x23455ba1 ./out,./artifacts

if [ $# -lt 1 ]; then
  echo "Usage: $0 <target-selector> [search_dirs_comma_separated]"
  echo "Example: $0 0x23455ba1 ./out,./artifacts"
  exit 1
fi

TARGET="$1"
# normalize target: ensure 0x prefix and lowercase, and keep only first 10 chars if user passed full keccak
if [[ "${TARGET:0:2}" != "0x" ]]; then TARGET="0x${TARGET}"; fi
TARGET="$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')"
# accept full hash or 4byte selector; if full hash passed, take leading 10 chars
if [[ ${#TARGET} -gt 10 ]]; then
  TARGET="${TARGET:0:10}"
fi

DIRS_INPUT="${2:-./out,./artifacts}"
IFS=',' read -r -a SEARCH_DIRS <<< "$DIRS_INPUT"

# check deps
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Please install jq."; exit 2; }
command -v cast >/dev/null 2>&1 || { echo "Error: cast (foundry) not found. Install foundry and ensure 'cast' is in PATH."; exit 3; }

echo "Searching for selector $TARGET in: ${SEARCH_DIRS[*]}"
echo

FOUND=0

for dir in "${SEARCH_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  # find json files (robust against nested dirs)
  find "$dir" -type f -name "*.json" | while read -r file; do
    # Extract ABI: if file is a wrapper object with .abi then use that, otherwise assume file content is ABI array
    abi_json=$(jq -c 'if type=="object" and .abi then .abi else . end' "$file" 2>/dev/null) || continue
    # iterate error fragments
    echo "$abi_json" | jq -c '.[]? | select(.type=="error") | {name: .name, inputs: (.inputs|map(.type)|join(","))}' 2>/dev/null \
    | while read -r frag; do
      name=$(echo "$frag" | jq -r '.name')
      inputs=$(echo "$frag" | jq -r '.inputs')
      # build signature (handle zero-input error)
      if [ -z "$inputs" ] || [ "$inputs" = "null" ]; then
        sig="${name}()"
      else
        sig="${name}(${inputs})"
      fi
      # compute selector
      sel=$(cast keccak "$sig" 2>/dev/null | cut -c1-10 || true)
      if [ -z "$sel" ]; then
        # if cast fails for some reason, skip
        continue
      fi
      if [ "$sel" = "$TARGET" ]; then
        echo "MATCH: $file -> $sig"
        FOUND=1
      fi
    done
  done
done

if [ "$FOUND" -eq 0 ]; then
  echo "No matches found for selector $TARGET."
  exit 4
else
  echo
  echo "Done."
  exit 0
fi

