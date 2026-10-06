#!/usr/bin/env bash
# Build an iPhoneOS arm64 wrapper against verified OpenCV 5 + contrib sources.
# Output and dependency caches are version-isolated; --deploy copies to Unity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build_ios/opencv5}"
OPENCV_VER="5.0.0"
OPENCV_DIR="${OPENCV_DIR:-$SCRIPT_DIR/opencv_ios/$OPENCV_VER}"
# The basic official zip lacks AKAZE. An optional archive is verified for
# provenance only; the runtime framework is built with pinned contrib sources.
OPENCV_SHA256="c844d3466f7999b6e920d4ee53c71310c4cdd34b13f1547f373723834e308b0e"
SOURCE_SHA256="b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095"
CONTRIB_SHA256="c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f"
OUTPUT_LIBRARY="${OUTPUT_LIBRARY:-$BUILD_DIR/libvisual_localizer.a}"
DEST="$SCRIPT_DIR/../unity_project/Assets/Plugins/iOS/libvisual_localizer.a"
DEPLOY=false

if [[ "${1:-}" == "--deploy" && $# == 1 ]]; then
    DEPLOY=true
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--deploy]" >&2
    echo "environment: BUILD_DIR OPENCV_DIR OUTPUT_LIBRARY OPENCV_BUILD_CACHE OPENCV_SOURCE_ARCHIVE OPENCV_CONTRIB_ARCHIVE" >&2
    exit 2
fi

echo "=== Building iOS arm64 static library ==="

# Step 1: Build the source framework once; never reuse a basic 4/5 cache.
if [[ -n "${OPENCV_ARCHIVE:-}" ]]; then
    ACTUAL_SHA256="$(shasum -a 256 "$OPENCV_ARCHIVE" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" != "$OPENCV_SHA256" ]]; then
        echo "ERROR: OpenCV $OPENCV_VER release SHA256 mismatch: $ACTUAL_SHA256" >&2
        exit 1
    fi
fi
OPENCV_FW="$OPENCV_DIR/opencv2.framework"
if [[ -d "$OPENCV_FW" && ! -f "$OPENCV_FW/dependency.json" ]]; then
    echo "ERROR: unverified/basic OpenCV cache lacks contrib provenance; choose a fresh OPENCV_DIR" >&2
    exit 1
fi
if [[ ! -f "$OPENCV_FW/dependency.json" ]]; then
    OPENCV_DIR="$OPENCV_DIR" bash "$SCRIPT_DIR/../tools/opencv5/build_ios_dependency.sh" \
        "${OPENCV_BUILD_CACHE:-$SCRIPT_DIR/build_ios/opencv5-dependency}"
fi
if [ ! -d "$OPENCV_FW" ]; then
    echo "ERROR: opencv2.framework not found at $OPENCV_FW"
    echo "Contents of $OPENCV_DIR:"
    ls -la "$OPENCV_DIR"
    exit 1
fi
VERSION_HEADER="$OPENCV_FW/Headers/core/version.hpp"
if [[ ! -f "$VERSION_HEADER" || ! -f "$OPENCV_FW/opencv2" || ! -f "$OPENCV_FW/Headers/xfeatures2d.hpp" ]]; then
    echo "ERROR: OpenCV 5 framework lacks the required native/contrib files" >&2
    exit 1
fi
for FIELD_VALUE in MAJOR:5 MINOR:0 REVISION:0; do
    FIELD="${FIELD_VALUE%:*}"
    VALUE="${FIELD_VALUE#*:}"
    if ! awk -v field="CV_VERSION_$FIELD" -v value="$VALUE" \
        '$1 == "#define" && $2 == field && $3 == value {found=1} END {exit !found}' "$VERSION_HEADER"; then
        echo "ERROR: cached OpenCV headers are not $OPENCV_VER" >&2
        exit 1
    fi
done
python3 - "$OPENCV_FW" "$SOURCE_SHA256" "$CONTRIB_SHA256" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
framework = Path(sys.argv[1])
metadata = json.loads((framework / "dependency.json").read_text())
expected = {"version": "5.0.0", "platform": "iphoneos", "architecture": "arm64",
            "sourceSHA256": sys.argv[2], "contribSHA256": sys.argv[3],
            "binarySHA256": hashlib.sha256((framework / "opencv2").read_bytes()).hexdigest()}
if any(metadata.get(key) != value for key, value in expected.items()):
    raise SystemExit("ERROR: stale/modified OpenCV 5 + contrib framework provenance")
PY
lipo "$OPENCV_FW/opencv2" -verify_arch arm64

echo "--- OpenCV framework: $OPENCV_FW ---"

# Step 2: Compile C++ sources for iOS arm64
mkdir -p "$BUILD_DIR"

SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
CXX=$(xcrun --sdk iphoneos --find clang++)

echo "--- Compiling visual_localizer.cpp ---"
$CXX -std=c++17 -O2 -DNDEBUG -arch arm64 -isysroot "$SYSROOT" \
    -miphoneos-version-min=14.0 \
    -I"$SCRIPT_DIR/include" \
    -I"$SCRIPT_DIR/src" \
    -F"$OPENCV_DIR" \
    -fvisibility=hidden -fvisibility-inlines-hidden \
    -fPIC \
    -c "$SCRIPT_DIR/src/visual_localizer.cpp" -o "$BUILD_DIR/visual_localizer.o"

echo "--- Compiling pose_contract.cpp ---"
$CXX -std=c++17 -O2 -DNDEBUG -arch arm64 -isysroot "$SYSROOT" \
    -miphoneos-version-min=14.0 \
    -I"$SCRIPT_DIR/include" \
    -I"$SCRIPT_DIR/src" \
    -F"$OPENCV_DIR" \
    -fvisibility=hidden -fvisibility-inlines-hidden \
    -fPIC \
    -c "$SCRIPT_DIR/src/pose_contract.cpp" -o "$BUILD_DIR/pose_contract.o"

echo "--- Compiling visual_localizer_impl.cpp ---"
$CXX -std=c++17 -O2 -DNDEBUG -arch arm64 -isysroot "$SYSROOT" \
    -miphoneos-version-min=14.0 \
    -I"$SCRIPT_DIR/include" \
    -I"$SCRIPT_DIR/src" \
    -F"$OPENCV_DIR" \
    -fvisibility=hidden -fvisibility-inlines-hidden \
    -fPIC \
    -c "$SCRIPT_DIR/src/visual_localizer_impl.cpp" -o "$BUILD_DIR/visual_localizer_impl.o"

# Step 3: Create static library
echo "--- Creating static library ---"
ar rcs "$BUILD_DIR/libvisual_localizer.a" \
    "$BUILD_DIR/visual_localizer.o" \
    "$BUILD_DIR/pose_contract.o" \
    "$BUILD_DIR/visual_localizer_impl.o"

# Step 4: Verify
echo "=== Verifying ==="
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$BUILD_DIR/libvisual_localizer.a"
# Resolve the entire wrapper and OpenCV archive for the device target. This
# catches missing transitive libraries that an archive symbol check cannot.
"$CXX" -std=c++17 -arch arm64 -isysroot "$SYSROOT" \
    -miphoneos-version-min=14.0 -I"$SCRIPT_DIR/include" \
    "$SCRIPT_DIR/tests/ios_link_smoke.cpp" \
    -Wl,-force_load,"$BUILD_DIR/libvisual_localizer.a" \
    -Wl,-force_load,"$OPENCV_FW/opencv2" \
    -framework Accelerate -framework Foundation -lz -lsqlite3 \
    -o "$BUILD_DIR/ios_link_smoke"
echo "PASS iPhoneOS arm64 complete native link"

# Step 5: An independent output is allowed; deployment is explicit.
if [[ "$OUTPUT_LIBRARY" != "$BUILD_DIR/libvisual_localizer.a" ]]; then
    mkdir -p "$(dirname "$OUTPUT_LIBRARY")"
    cp "$BUILD_DIR/libvisual_localizer.a" "$OUTPUT_LIBRARY"
fi
if [[ "$DEPLOY" == true ]]; then
    cp "$OUTPUT_LIBRARY" "$DEST"
    echo "=== Copied to $DEST ==="
fi
echo "=== Built $OUTPUT_LIBRARY with OpenCV + contrib $OPENCV_VER ==="
