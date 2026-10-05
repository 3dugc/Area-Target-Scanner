#!/usr/bin/env bash
# Build the minimal static iPhoneOS framework, including OpenCV 5's AKAZE.
# The basic release framework omits xfeatures2d; pin both source archives.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_DIR="${1:-$ROOT/build/opencv5-ios}"
OPENCV_DIR="${OPENCV_DIR:-$ROOT/native_visual_localizer/opencv_ios/5.0.0}"
VERSION="5.0.0"
SOURCE_SHA256="b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095"
CONTRIB_SHA256="c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f"
SOURCE_ARCHIVE="${OPENCV_SOURCE_ARCHIVE:-$CACHE_DIR/opencv-$VERSION.tar.gz}"
CONTRIB_ARCHIVE="${OPENCV_CONTRIB_ARCHIVE:-$CACHE_DIR/opencv_contrib-$VERSION.tar.gz}"

prepare_source() {
    local project="$1" archive="$2" expected="$3"
    mkdir -p "$(dirname "$archive")"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --retry 3 --silent --show-error \
            "https://github.com/opencv/$project/archive/refs/tags/$VERSION.tar.gz" \
            --output "$archive.part"
        mv "$archive.part" "$archive"
    fi
    python3 "$ROOT/tools/opencv5/verify_source.py" \
        "$archive" "$expected" "$CACHE_DIR/$project-$VERSION"
}

mkdir -p "$CACHE_DIR" "$OPENCV_DIR"
prepare_source opencv "$SOURCE_ARCHIVE" "$SOURCE_SHA256"
prepare_source opencv_contrib "$CONTRIB_ARCHIVE" "$CONTRIB_SHA256"
SOURCE="$CACHE_DIR/opencv-$VERSION"
CONTRIB="$CACHE_DIR/opencv_contrib-$VERSION"
BUILD_DIR="$CACHE_DIR/dependency-ios5-arm64"
PREFIX="$CACHE_DIR/install-ios5"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

run_step() {
    local name="$1"
    shift
    local log="$CACHE_DIR/$name.log"
    printf 'OpenCV iPhoneOS %s (log: %s)\n' "$name" "$log"
    if ! "$@" >"$log" 2>&1; then
        tail -n 80 "$log" >&2
        exit 1
    fi
}

run_step configure cmake -S "$SOURCE" -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DOPENCV_EXTRA_MODULES_PATH="$CONTRIB/modules" \
    -DBUILD_LIST=core,imgproc,features,geometry,xfeatures2d \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF \
    -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
    -DOPENCV_SKIP_FEATURES2D_DOWNLOADING=ON -DOPENCV_ENABLE_NONFREE=OFF \
    -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_LAPACK=OFF \
    -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_VTK=OFF \
    -DWITH_OPENGL=OFF -DWITH_PROTOBUF=OFF -DWITH_ADE=OFF
run_step build cmake --build "$BUILD_DIR" --parallel "${JOBS:-4}"
run_step install cmake --install "$BUILD_DIR"

FRAMEWORK="$OPENCV_DIR/opencv2.framework"
mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Licenses"
cp -R "$PREFIX/include/opencv5/opencv2/." "$FRAMEWORK/Headers/"
LIBRARIES=("$PREFIX"/lib/libopencv_*.a)
if [[ ! -f "${LIBRARIES[0]}" ]]; then
    echo "ERROR: iPhoneOS static OpenCV libraries were not installed" >&2
    exit 1
fi
shopt -s nullglob
THIRD_PARTY_LIBRARIES=("$PREFIX"/lib/opencv5/3rdparty/*.a)
shopt -u nullglob
run_step framework libtool -static -o "$FRAMEWORK/opencv2" "${LIBRARIES[@]}" "${THIRD_PARTY_LIBRARIES[@]}"
lipo -verify_arch arm64 "$FRAMEWORK/opencv2"
cp -R "$PREFIX/share/licenses/opencv5/." "$FRAMEWORK/Licenses/"
cp "$SOURCE/LICENSE" "$FRAMEWORK/Licenses/OpenCV-LICENSE.txt"
cp "$CONTRIB/LICENSE" "$FRAMEWORK/Licenses/OpenCV-Contrib-LICENSE.txt"
cp "$CONTRIB/modules/xfeatures2d/src/kaze/LICENSE.AKAZE" "$FRAMEWORK/Licenses/AKAZE-LICENSE.txt"
cp "$CONTRIB/modules/xfeatures2d/src/kaze/LICENSE.KAZE" "$FRAMEWORK/Licenses/KAZE-LICENSE.txt"
if [[ -f "$PREFIX/lib/opencv5/3rdparty/libtegra_hal.a" ]]; then
    # Carotene embeds its BSD license in the public header rather than a file.
    sed -n '1,/^ \*\//p' "$SOURCE/hal/carotene/include/carotene/functions.hpp" \
        >"$FRAMEWORK/Licenses/Carotene-LICENSE.txt"
fi
if [[ -f "$PREFIX/lib/opencv5/3rdparty/libkleidicv.a" ]]; then
    KLEIDICV_DIRS=("$BUILD_DIR"/3rdparty/kleidicv/kleidicv-*)
    cp "${KLEIDICV_DIRS[0]}/LICENSES/Apache-2.0.txt" "$FRAMEWORK/Licenses/KleidiCV-Apache-2.0.txt"
    cp "${KLEIDICV_DIRS[0]}/README.md" "$FRAMEWORK/Licenses/KleidiCV-README.md"
fi
python3 - "$FRAMEWORK" "$SOURCE_SHA256" "$CONTRIB_SHA256" <<'PY'
import hashlib
import json
import plistlib
import sys
from pathlib import Path
framework = Path(sys.argv[1])
info = {"CFBundleExecutable": "opencv2", "CFBundleIdentifier": "org.opencv",
        "CFBundleName": "opencv2", "CFBundlePackageType": "FMWK",
        "CFBundleVersion": "5.0.0", "CFBundleShortVersionString": "5.0.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "14.0"}
(framework / "Info.plist").write_bytes(plistlib.dumps(info))
metadata = {"version": "5.0.0", "platform": "iphoneos", "architecture": "arm64",
            "sourceSHA256": sys.argv[2], "contribSHA256": sys.argv[3],
            "modules": ["core", "imgproc", "features", "flann", "geometry", "xfeatures2d"],
            "binarySHA256": hashlib.sha256((framework / "opencv2").read_bytes()).hexdigest()}
(framework / "dependency.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
printf 'OpenCV iPhoneOS framework: %s\n' "$FRAMEWORK"
