#!/usr/bin/env bash
# Build script for the current macOS host architecture.
# Prerequisites: brew install opencv cmake
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_LIBRARY="$SCRIPT_DIR/build/libvisual_localizer.dylib"
ARCHITECTURES="${MACOS_ARCHITECTURES:-$(uname -m)}"
DEPLOY=false

if [[ "${1:-}" == "--deploy" ]]; then
    DEPLOY=true
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--deploy]" >&2
    exit 2
fi

echo "=== Building macOS binary for $ARCHITECTURES ==="

# Configure with CMake
cmake -B "$SCRIPT_DIR/build" \
    -S "$SCRIPT_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURES" \
    -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build "$SCRIPT_DIR/build" --config Release

# Verify the output
if [ ! -f "$OUTPUT_LIBRARY" ]; then
    echo "ERROR: $OUTPUT_LIBRARY not found"
    exit 1
fi

echo "=== Verifying native contract ==="
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$OUTPUT_LIBRARY"

if [[ "$DEPLOY" == true ]]; then
    DEST="$SCRIPT_DIR/../unity_project/Assets/Plugins/macOS/libvisual_localizer.dylib"
    cp "$OUTPUT_LIBRARY" "$DEST"
    echo "=== Copied to $DEST ==="
fi

echo "=== Done ==="
