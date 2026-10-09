#!/usr/bin/env bash
# Build against a selected OpenCV install without replacing Unity artifacts.
# For a 4.x baseline set OPENCV_REQUIRED_MAJOR=4 and OpenCV_DIR explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCV_REQUIRED_MAJOR="${OPENCV_REQUIRED_MAJOR:-5}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/macos_opencv$OPENCV_REQUIRED_MAJOR}"
OUTPUT_LIBRARY="${OUTPUT_LIBRARY:-$BUILD_DIR/libvisual_localizer.dylib}"
ARCHITECTURES="${MACOS_ARCHITECTURES:-$(uname -m)}"
DEPLOY=false

if [[ "${1:-}" == "--deploy" && $# == 1 ]]; then
    DEPLOY=true
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--deploy]" >&2
    echo "environment: OpenCV_DIR BUILD_DIR OUTPUT_LIBRARY OPENCV_REQUIRED_MAJOR MACOS_ARCHITECTURES" >&2
    exit 2
fi

if [[ "$OPENCV_REQUIRED_MAJOR" != 4 && "$OPENCV_REQUIRED_MAJOR" != 5 ]]; then
    echo "ERROR: OPENCV_REQUIRED_MAJOR must be 4 or 5" >&2
    exit 2
fi
echo "=== Building macOS OpenCV $OPENCV_REQUIRED_MAJOR for $ARCHITECTURES ==="

# Configure with CMake
CONFIGURE_ARGS=(
    -B "$BUILD_DIR" -S "$SCRIPT_DIR"
    -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURES"
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
    -DOPENCV_REQUIRED_MAJOR="$OPENCV_REQUIRED_MAJOR"
)
if [[ -n "${OpenCV_DIR:-}" ]]; then
    CONFIGURE_ARGS+=(-DOpenCV_DIR="$OpenCV_DIR")
fi
cmake "${CONFIGURE_ARGS[@]}"

# Build
cmake --build "$BUILD_DIR" --config Release

echo "=== Running native localization contract tests ==="
ctest --test-dir "$BUILD_DIR" --output-on-failure

# Verify the output
BUILT_LIBRARY="$BUILD_DIR/libvisual_localizer.dylib"
if [ ! -f "$BUILT_LIBRARY" ]; then
    echo "ERROR: $BUILT_LIBRARY not found"
    exit 1
fi

echo "=== Verifying native contract ==="
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$BUILT_LIBRARY"
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$BUILT_LIBRARY" "$SCRIPT_DIR/../tools/phase0/required_combined_native_symbols.txt"
if [[ "$OUTPUT_LIBRARY" != "$BUILT_LIBRARY" ]]; then
    mkdir -p "$(dirname "$OUTPUT_LIBRARY")"
    cp "$BUILT_LIBRARY" "$OUTPUT_LIBRARY"
fi

if [[ "$DEPLOY" == true ]]; then
    DEST="$SCRIPT_DIR/../unity_project/Assets/Plugins/macOS/libvisual_localizer.dylib"
    cp "$OUTPUT_LIBRARY" "$DEST"
    echo "=== Copied to $DEST ==="
fi

echo "=== Built $OUTPUT_LIBRARY ==="
