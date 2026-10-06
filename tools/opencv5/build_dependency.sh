#!/usr/bin/env bash
# Build a pinned native dependency without replacing the system OpenCV.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_DIR="${1:-$ROOT/build/opencv5}"
VERSION="5.0.0"
SOURCE_SHA256="b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095"
CONTRIB_SHA256="c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f"
ARCHIVE="$CACHE_DIR/opencv-$VERSION.tar.gz"
SOURCE="$CACHE_DIR/opencv-$VERSION"
CONTRIB_ARCHIVE="$CACHE_DIR/opencv_contrib-$VERSION.tar.gz"
CONTRIB_SOURCE="$CACHE_DIR/opencv_contrib-$VERSION"
PREFIX="$CACHE_DIR/install"

mkdir -p "$CACHE_DIR"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 --silent --show-error \
        "https://github.com/opencv/opencv/archive/refs/tags/$VERSION.tar.gz" \
        --output "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
python3 "$ROOT/tools/opencv5/verify_source.py" "$ARCHIVE" "$SOURCE_SHA256" "$SOURCE"
if [[ ! -f "$CONTRIB_ARCHIVE" ]]; then
    curl --fail --location --retry 3 --silent --show-error \
        "https://github.com/opencv/opencv_contrib/archive/refs/tags/$VERSION.tar.gz" \
        --output "$CONTRIB_ARCHIVE.part"
    mv "$CONTRIB_ARCHIVE.part" "$CONTRIB_ARCHIVE"
fi
python3 "$ROOT/tools/opencv5/verify_source.py" "$CONTRIB_ARCHIVE" "$CONTRIB_SHA256" "$CONTRIB_SOURCE"

cmake -S "$SOURCE" -B "$CACHE_DIR/dependency-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DOPENCV_EXTRA_MODULES_PATH="$CONTRIB_SOURCE/modules" \
    -DBUILD_LIST=core,imgproc,features,geometry,xfeatures2d \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
    -DOPENCV_SKIP_FEATURES2D_DOWNLOADING=ON \
    -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF \
    -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
    -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_FFMPEG=OFF \
    -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
    -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_OPENEXR=OFF -DWITH_AVIF=OFF \
    -DWITH_PROTOBUF=OFF -DWITH_ADE=OFF -DWITH_TESSERACT=OFF -DWITH_EIGEN=OFF \
    -DWITH_GSTREAMER=OFF -DWITH_VTK=OFF -DOPENCV_GENERATE_PKGCONFIG=ON
cmake --build "$CACHE_DIR/dependency-build" --parallel "${JOBS:-4}"
cmake --install "$CACHE_DIR/dependency-build"
printf 'OpenCV_DIR=%s\n' "$PREFIX/lib/cmake/opencv5"
