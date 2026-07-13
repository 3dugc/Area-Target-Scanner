#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNITY_PATH="${UNITY_PATH:-/Applications/Unity/Hub/Editor/6000.4.6f1/Unity.app/Contents/MacOS/Unity}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RESULTS="$ROOT/phase1-results"
PROJECT="$(mktemp -d -t area-target-phase1-upm-ios)"

[[ -x "$UNITY_PATH" ]] || { echo "Unity not found: $UNITY_PATH" >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found" >&2; exit 2; }
mkdir -p "$RESULTS"

echo "UPM iOS validation project: $PROJECT"
echo "Logs: $RESULTS"

"$PYTHON_BIN" "$ROOT/tools/phase0/build_upm_package.py"
VERSION="$("$PYTHON_BIN" "$ROOT/tools/phase0/check_package_metadata.py" "$ROOT/unity_plugin/AreaTargetPlugin/package.json")"
PACKAGE="$ROOT/dist/com.areatarget.tracking-$VERSION.tgz"
[[ -f "$PACKAGE" ]] || { echo "UPM archive not found: $PACKAGE" >&2; exit 3; }

"$UNITY_PATH" -batchmode -nographics -createProject "$PROJECT" -quit \
  -logFile "$RESULTS/upm-ios-create-project.log"

mkdir -p "$PROJECT/Assets/Editor" "$PROJECT/Assets/Scenes" "$PROJECT/Assets/Scripts"
cp "$ROOT/unity_project/Assets/Editor/BuildiOS.cs" "$PROJECT/Assets/Editor/BuildiOS.cs"
cp "$ROOT/unity_project/Assets/Scenes/TestScene.unity" "$PROJECT/Assets/Scenes/TestScene.unity"
cp "$ROOT/unity_project/Assets/Scenes/TestScene.unity.meta" "$PROJECT/Assets/Scenes/TestScene.unity.meta"
cp "$ROOT/unity_project/Assets/Scripts/TestSceneManager.cs" "$PROJECT/Assets/Scripts/TestSceneManager.cs"
cp "$ROOT/unity_project/Assets/Scripts/TestSceneManager.cs.meta" "$PROJECT/Assets/Scripts/TestSceneManager.cs.meta"

"$PYTHON_BIN" - "$PROJECT/Packages/manifest.json" "$PACKAGE" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
package_path = Path(sys.argv[2]).resolve()
data = json.loads(manifest_path.read_text())
dependencies = data.setdefault("dependencies", {})
scoped_registries = data.setdefault("scopedRegistries", [])
if not any("com.gilzoide" in registry.get("scopes", []) for registry in scoped_registries):
    scoped_registries.append({
        "name": "OpenUPM",
        "url": "https://package.openupm.com",
        "scopes": ["com.gilzoide"],
    })
# Unity 6000.4 accepts file:/absolute/path but rejects pathlib's file:/// URI.
dependencies["com.areatarget.tracking"] = "file:" + package_path.as_posix()
manifest_path.write_text(json.dumps(data, indent=2) + "\n")
PY

"$UNITY_PATH" -batchmode -nographics -projectPath "$PROJECT" -quit \
  -logFile "$RESULTS/upm-ios-clean-install.log"

if rg -n "error CS|Scripts have compiler errors|Failed to resolve packages" "$RESULTS/upm-ios-clean-install.log"; then
  echo "Unity clean UPM install failed; see $RESULTS/upm-ios-clean-install.log" >&2
  exit 4
fi

"$UNITY_PATH" -batchmode -nographics -projectPath "$PROJECT" \
  -executeMethod AreaTargetPlugin.Editor.AreaTargetIosXrBootstrap.Configure -quit \
  -logFile "$RESULTS/upm-ios-configure-arkit.log"

if rg -n "error CS|Scripts have compiler errors|BuildFailedException|could not assign" \
  "$RESULTS/upm-ios-configure-arkit.log"; then
  echo "Unity ARKit configuration failed; see $RESULTS/upm-ios-configure-arkit.log" >&2
  exit 5
fi

"$UNITY_PATH" -batchmode -nographics -projectPath "$PROJECT" -buildTarget iOS \
  -executeMethod BuildiOS.BuildDevelopment -quit \
  -logFile "$RESULTS/upm-ios-export.log"

XCODE_PROJECT="$PROJECT/Builds/iOS_Dev/Unity-iPhone.xcodeproj"
[[ -d "$XCODE_PROJECT" ]] || { echo "Unity iOS export missing: $XCODE_PROJECT" >&2; exit 6; }

ARKIT_LIBRARY="libUnityARKit.a"
if ! rg -F -q "$ARKIT_LIBRARY" "$XCODE_PROJECT/project.pbxproj"; then
  echo "Unity iOS export omitted the ARKit runtime provider; see $XCODE_PROJECT/project.pbxproj" >&2
  exit 7
fi

XCODE_LOG="$RESULTS/upm-ios-xcodebuild.log"
if ! xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme Unity-iPhone \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build >"$XCODE_LOG" 2>&1; then
  echo "generic iOS Xcode build failed; see $XCODE_LOG" >&2
  exit 8
fi

if ! rg -q "BUILD SUCCEEDED" "$XCODE_LOG"; then
  echo "generic iOS Xcode build did not report BUILD SUCCEEDED; see $XCODE_LOG" >&2
  exit 9
fi

echo "PASS clean UPM install, Unity iOS export, and generic iOS Xcode build"
