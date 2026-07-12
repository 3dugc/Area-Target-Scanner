#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNITY_PATH="${UNITY_PATH:-/Applications/Unity/Hub/Editor/6000.3.11f1/Unity.app/Contents/MacOS/Unity}"
RESULTS="$ROOT/phase0-results"
PROJECT="/tmp/area-target-phase0-unity"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[[ -x "$UNITY_PATH" ]] || { echo "Unity not found: $UNITY_PATH" >&2; exit 2; }
mkdir -p "$RESULTS"

"$UNITY_PATH" -batchmode -nographics \
  -projectPath "$ROOT/unity_project" \
  -runTests -testPlatform EditMode \
  -testResults "$RESULTS/unity-editmode.xml" \
  -logFile "$RESULTS/unity-editmode.log"

"$PYTHON_BIN" - "$RESULTS/unity-editmode.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
total = int(root.attrib.get("total", "0"))
failed = int(root.attrib.get("failed", "1"))
if total <= 0 or failed != 0:
    raise SystemExit(f"Unity tests invalid: total={total}, failed={failed}")
PY

"$PYTHON_BIN" "$ROOT/tools/phase0/build_upm_package.py"
VERSION="$("$PYTHON_BIN" "$ROOT/tools/phase0/check_package_metadata.py" "$ROOT/unity_plugin/AreaTargetPlugin/package.json")"
PACKAGE="$ROOT/dist/com.areatarget.tracking-$VERSION.tgz"

rm -rf "$PROJECT"
"$UNITY_PATH" -batchmode -nographics -createProject "$PROJECT" -quit -logFile "$RESULTS/unity-create.log"

"$PYTHON_BIN" - "$PROJECT/Packages/manifest.json" "$PACKAGE" <<'PY'
import json
import sys
from pathlib import Path
manifest_path = Path(sys.argv[1])
package_path = Path(sys.argv[2]).resolve()
data = json.loads(manifest_path.read_text())
dependencies = data.setdefault("dependencies", {})
dependencies["com.gilzoide.sqlite-net"] = "https://github.com/gilzoide/unity-sqlite-net.git#1.3.2"
dependencies["com.areatarget.tracking"] = package_path.as_uri()
manifest_path.write_text(json.dumps(data, indent=2) + "\n")
PY

"$UNITY_PATH" -batchmode -nographics -projectPath "$PROJECT" -quit \
  -logFile "$RESULTS/unity-clean-install.log"

if rg -n "error CS|Scripts have compiler errors|Failed to resolve packages" "$RESULTS/unity-clean-install.log"; then
  echo "Unity clean install failed" >&2
  exit 3
fi

rm -rf "$PROJECT"
echo "PASS Unity EditMode and clean UPM install"
