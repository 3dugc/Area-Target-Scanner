#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${1:?usage: check_native_symbols.sh <library>}"
SYMBOLS="$ROOT/tools/phase0/required_native_symbols.txt"

if [[ ! -f "$LIB" ]]; then
  echo "FAIL missing library: $LIB" >&2
  exit 2
fi
if [[ ! -s "$LIB" ]]; then
  echo "FAIL empty library: $LIB" >&2
  exit 2
fi

FILE_OUTPUT="$(file "$LIB")"
echo "$FILE_OUTPUT"
if [[ "$FILE_OUTPUT" != *"Mach-O"* && "$FILE_OUTPUT" != *"ar archive"* ]]; then
  echo "FAIL unrecognized native library format: $LIB" >&2
  exit 2
fi

if command -v lipo >/dev/null 2>&1; then
  lipo -info "$LIB"
fi

NM_OUTPUT="$(nm "$LIB")"
while IFS= read -r symbol; do
  [[ -z "$symbol" ]] && continue
  if ! grep -Eq "[[:space:]_]${symbol}$" <<<"$NM_OUTPUT"; then
    echo "FAIL missing symbol: $symbol" >&2
    exit 3
  fi
done < "$SYMBOLS"

echo "PASS native contract: $LIB"
