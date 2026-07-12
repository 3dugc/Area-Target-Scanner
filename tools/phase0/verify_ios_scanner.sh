#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS="$ROOT/phase0-results/xcode"
mkdir -p "$RESULTS"
xcodebuild \
  -project "$ROOT/ios_scanner/AreaTargetScanner.xcodeproj" \
  -scheme AreaTargetScanner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RESULTS/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build | tee "$RESULTS/build.log"
