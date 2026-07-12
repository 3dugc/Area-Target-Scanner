# Phase 0 Reproducible Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The current user requested single-agent execution, so use `superpowers:executing-plans` unless that constraint changes.

**Goal:** Produce a clean, repeatable `v1.2.1` baseline whose scanner, Docker pipeline, Python suite, native artifacts, Unity tests, and UPM package can be verified from a clean checkout.

**Architecture:** Preserve the current Swift/Python/C++/Unity architecture. Add small verification and packaging tools under `tools/phase0`, make `package.json` the version authority, remove generated repository artifacts, and orchestrate existing build/test commands through one fail-fast entry point.

**Tech Stack:** Python 3.11, Bash/zsh, Docker Compose, CMake/OpenCV, Xcode, Unity 6000.3.11f1, UPM, GitHub Actions.

**Source of truth:** `requirements.md` and `design.md` in this directory.

---

## Progress rules

- Execute tasks in numeric order.
- Mark a child checkbox complete only after its command has produced the expected result.
- Keep the parent task unchecked until every required child is complete.
- Before each task commit, update this file's completed checkboxes and include `tasks.md` in the same commit.
- Record a blocker under the affected checkbox; do not substitute a passing claim.
- Do not implement Rokid, Android ARM64, coordinate alignment, async localization, or algorithm tuning in this plan.

## Task 1: Canonical package metadata and version

**Requirements:** R0.2, R0.3

**Files:**

- Create: `tools/phase0/check_package_metadata.py`
- Create: `tests/phase0/test_package_metadata.py`
- Modify: `unity_plugin/AreaTargetPlugin/package.json`
- Modify: `unity_plugin/AreaTargetPlugin/CHANGELOG.md`
- Modify: `unity_project/Assets/Editor/PackageExporter.cs`

- [ ] **Step 1: Add failing metadata tests**

Create `tests/phase0/test_package_metadata.py`:

```python
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase0/check_package_metadata.py"
PACKAGE_JSON = ROOT / "unity_plugin/AreaTargetPlugin/package.json"


def run_checker(path: Path):
    return subprocess.run(
        [sys.executable, str(CHECKER), str(path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


def test_current_package_metadata_is_canonical():
    result = run_checker(PACKAGE_JSON)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "1.2.1"


def test_duplicate_json_key_is_rejected(tmp_path):
    path = tmp_path / "package.json"
    path.write_text('{"version":"1.2.1","dependencies":{},"dependencies":{}}')
    result = run_checker(path)
    assert result.returncode != 0
    assert "duplicate key" in result.stderr.lower()


def test_required_dependencies_are_enforced(tmp_path):
    data = json.loads(PACKAGE_JSON.read_text())
    data["dependencies"].pop("com.gilzoide.sqlite-net", None)
    path = tmp_path / "package.json"
    path.write_text(json.dumps(data))
    result = run_checker(path)
    assert result.returncode != 0
    assert "com.gilzoide.sqlite-net" in result.stderr
```

- [ ] **Step 2: Run the metadata tests and confirm failure**

Run:

```bash
python3 -m pytest tests/phase0/test_package_metadata.py -v
```

Expected: FAIL because the checker does not exist and `package.json` still contains duplicate `dependencies` keys/version `1.2.0`.

- [ ] **Step 3: Implement the strict metadata checker**

Create `tools/phase0/check_package_metadata.py`:

```python
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

EXPECTED_VERSION = "1.2.1"
EXPECTED_DEPENDENCIES = {
    "com.unity.xr.arfoundation": "6.0.0",
    "com.gilzoide.sqlite-net": "1.3.2",
}


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def main() -> int:
    path = Path(sys.argv[1])
    try:
        data = json.loads(path.read_text(), object_pairs_hook=reject_duplicates)
        if data.get("version") != EXPECTED_VERSION:
            raise ValueError(f"version must be {EXPECTED_VERSION}")
        dependencies = data.get("dependencies", {})
        for name, version in EXPECTED_DEPENDENCIES.items():
            if dependencies.get(name) != version:
                raise ValueError(f"{name} must be {version}")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"metadata error: {exc}", file=sys.stderr)
        return 2
    print(data["version"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Normalize `package.json` and set version `1.2.1`**

Keep one `dependencies` object with exactly:

```json
"dependencies": {
  "com.unity.xr.arfoundation": "6.0.0",
  "com.gilzoide.sqlite-net": "1.3.2"
}
```

Set:

```json
"version": "1.2.1"
```

- [ ] **Step 5: Remove the independent PackageExporter version constant**

Replace the constant in `PackageExporter.cs` with package metadata loading:

```csharp
[System.Serializable]
private class PackageManifest
{
    public string version;
}

private static string ReadPackageVersion()
{
    const string manifestPath = "Packages/com.areatarget.tracking/package.json";
    var json = File.ReadAllText(Path.GetFullPath(manifestPath));
    var manifest = JsonUtility.FromJson<PackageManifest>(json);
    if (manifest == null || string.IsNullOrWhiteSpace(manifest.version))
        throw new InvalidDataException($"Missing version in {manifestPath}");
    return manifest.version;
}
```

Use `ReadPackageVersion()` when constructing the output filename.

- [ ] **Step 6: Add the `1.2.1` changelog entry**

Document only Phase 0 metadata, packaging, verification, CI, and repository-hygiene changes. Do not claim Rokid or Android support.

- [ ] **Step 7: Run metadata tests**

Run:

```bash
python3 -m pytest tests/phase0/test_package_metadata.py -v
```

Expected: all tests PASS and checker stdout is `1.2.1`.

- [ ] **Step 8: Commit Task 1**

```bash
git add tools/phase0/check_package_metadata.py tests/phase0/test_package_metadata.py unity_plugin/AreaTargetPlugin/package.json unity_plugin/AreaTargetPlugin/CHANGELOG.md unity_project/Assets/Editor/PackageExporter.cs docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "chore: establish canonical package version"
```

## Task 2: Repository hygiene and fixture ownership

**Requirements:** R0.1

**Files:**

- Create: `tests/phase0/test_repository_hygiene.py`
- Create: `unity_project/Assets/StreamingAssets/README.md`
- Modify: `.gitignore`
- Delete: generated XML/crash/backup artifacts enumerated below

- [ ] **Step 1: Add a failing repository-hygiene test**

Create `tests/phase0/test_repository_hygiene.py`:

```python
import re
import subprocess

FORBIDDEN = [
    re.compile(r"^unity_project/mono_crash\..*\.json$"),
    re.compile(r"^unity_project/(?:.*?/)?(?:TestResults|test_results|unity_test_results|pbt_).*\.xml$"),
    re.compile(r"\.(?:bak2|data1_bak)(?:\.meta)?$"),
    re.compile(r"^unity_project/unity_project/"),
]


def test_generated_artifacts_are_not_tracked():
    tracked = subprocess.check_output(
        ["git", "ls-files"], text=True
    ).splitlines()
    violations = [
        path for path in tracked if any(pattern.search(path) for pattern in FORBIDDEN)
    ]
    assert violations == []
```

- [ ] **Step 2: Run the hygiene test and confirm it lists current artifacts**

Run:

```bash
python3 -m pytest tests/phase0/test_repository_hygiene.py -v
```

Expected: FAIL and list tracked crash XML/backup paths.

- [ ] **Step 3: Prove retained fixture usage before cleanup**

Run:

```bash
rg -n "SLAMTestAssets|StreamingAssets/ScanData" unity_plugin unity_project tests
```

Expected: active tests reference `SLAMTestAssets` and recorded scan sequences. Retain their canonical files.

- [ ] **Step 4: Remove generated artifacts from Git**

Remove the exact generated groups:

```bash
git rm unity_project/mono_crash.*.json
git rm unity_project/TestResults-*.xml unity_project/debug/unity_test_results_slam.xml
git rm unity_project/pbt_results_final.xml unity_project/pbt_test_results*.xml
git rm unity_project/test_results_*.xml unity_project/unity_test_results.xml
git rm -r unity_project/unity_project
git rm unity_project/Assets/StreamingAssets/SLAMTestAssets/*.bak2*
git rm unity_project/Assets/StreamingAssets/SLAMTestAssets/*.data1_bak*
```

- [ ] **Step 5: Extend `.gitignore`**

Add:

```gitignore
# Generated verification reports
unity_project/*test_results*.xml
unity_project/TestResults-*.xml
unity_project/pbt_*.xml
unity_project/mono_crash.*.json
unity_project/unity_project/

# Asset backup variants
*.bak2
*.bak2.meta
*.data1_bak
*.data1_bak.meta

# Phase 0 build products
dist/
phase0-results/
```

- [ ] **Step 6: Document retained fixtures**

Create `unity_project/Assets/StreamingAssets/README.md` listing:

- `SLAMTestAssets`: deterministic packaged asset used by Unity localization regression tests.
- `ScanData` and `ScanData_data1`: recorded sequences used by playback and cross-session tests.
- A rule that replacements require updating the relevant tests and recording origin/date.

- [ ] **Step 7: Run the hygiene test and full repository search**

```bash
python3 -m pytest tests/phase0/test_repository_hygiene.py -v
git ls-files | rg 'mono_crash|test_results|TestResults|\.bak2|data1_bak' && exit 1 || true
```

Expected: hygiene test PASS; search prints no tracked matches.

- [ ] **Step 8: Commit Task 2**

```bash
git add .gitignore tests/phase0/test_repository_hygiene.py unity_project/Assets/StreamingAssets/README.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_project
git commit -m "chore: remove generated repository artifacts"
```

## Task 3: Native symbol contract and placeholder cleanup

**Requirements:** R0.4

**Files:**

- Create: `tools/phase0/required_native_symbols.txt`
- Create: `tools/phase0/check_native_symbols.sh`
- Create: `tests/phase0/test_native_contract.py`
- Modify: `native_visual_localizer/build_macos.sh`
- Modify: `native_visual_localizer/build_ios.sh`
- Delete: empty Windows/Linux placeholder binaries and their `.meta`

- [ ] **Step 1: Define the required native API**

Create `tools/phase0/required_native_symbols.txt`:

```text
vl_create
vl_destroy
vl_add_vocabulary_word
vl_add_keyframe
vl_add_keyframe_akaze
vl_build_index
vl_process_frame
vl_process_frame_out
vl_reset
vl_set_alignment_transform
vl_get_debug_info
```

- [ ] **Step 2: Add failing native-contract tests**

Create `tests/phase0/test_native_contract.py`:

```python
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase0/check_native_symbols.sh"
IOS_LIB = ROOT / "unity_project/Assets/Plugins/iOS/libvisual_localizer.a"


def test_ios_archive_matches_native_contract():
    result = subprocess.run([str(CHECKER), str(IOS_LIB)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_empty_library_is_rejected(tmp_path):
    empty = tmp_path / "empty.so"
    empty.touch()
    result = subprocess.run([str(CHECKER), str(empty)], text=True, capture_output=True)
    assert result.returncode != 0
    assert "empty" in (result.stdout + result.stderr).lower()
```

- [ ] **Step 3: Run tests and confirm checker-missing failure**

```bash
python3 -m pytest tests/phase0/test_native_contract.py -v
```

Expected: FAIL because the checker does not exist.

- [ ] **Step 4: Implement the native checker**

Create executable `tools/phase0/check_native_symbols.sh`:

```bash
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

file "$LIB"
NM_OUTPUT="$(nm "$LIB")"
while IFS= read -r symbol; do
  [[ -z "$symbol" ]] && continue
  if ! grep -Eq "[[:space:]_]${symbol}$" <<<"$NM_OUTPUT"; then
    echo "FAIL missing symbol: $symbol" >&2
    exit 3
  fi
done < "$SYMBOLS"

echo "PASS native contract: $LIB"
```

Run `chmod +x tools/phase0/check_native_symbols.sh`.

- [ ] **Step 5: Reuse the contract from both build scripts**

Replace duplicated `nm | grep` lists with:

```bash
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$OUTPUT_LIBRARY"
```

Resolve the repository root correctly from each script. Make macOS deployment opt-in via `--deploy`; the default build verifies its build-directory output without modifying tracked plugin binaries.

- [ ] **Step 6: Remove empty unsupported placeholders**

```bash
git rm unity_project/Assets/Plugins/x86_64/libvisual_localizer.so
git rm unity_project/Assets/Plugins/x86_64/libvisual_localizer.so.meta
git rm unity_project/Assets/Plugins/x86_64-win/visual_localizer.dll
git rm unity_project/Assets/Plugins/x86_64-win/visual_localizer.dll.meta
```

- [ ] **Step 7: Run native-contract tests and macOS build**

```bash
python3 -m pytest tests/phase0/test_native_contract.py -v
native_visual_localizer/build_macos.sh
tools/phase0/check_native_symbols.sh native_visual_localizer/build/libvisual_localizer.dylib
```

Expected: all tests PASS and both iOS/macOS artifacts report every required symbol.

- [ ] **Step 8: Commit Task 3**

```bash
git add tools/phase0 native_visual_localizer tests/phase0 docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_project/Assets/Plugins
git commit -m "build: enforce native artifact contract"
```

## Task 4: Reproducible UPM package

**Requirements:** R0.5

**Files:**

- Create: `tools/phase0/build_upm_package.py`
- Create: `tests/phase0/test_upm_package.py`
- Modify: `unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md`
- Delete: tracked stale `1.2.0` archives

- [ ] **Step 1: Add failing package-content tests**

Create `tests/phase0/test_upm_package.py` with these assertions:

```python
import hashlib
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/phase0/build_upm_package.py"
OUTPUT = ROOT / "dist/com.areatarget.tracking-1.2.1.tgz"

REQUIRED = {
    "package/package.json",
    "package/Runtime/AlignmentTransformCalculator.cs",
    "package/Runtime/ExtendedDebugInfo.cs",
    "package/Runtime/GLBMeshLoader.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
    "package/Runtime/Plugins/macOS/libvisual_localizer.dylib",
}


def build():
    subprocess.run([sys.executable, str(BUILDER)], cwd=ROOT, check=True)
    return hashlib.sha256(OUTPUT.read_bytes()).hexdigest()


def test_package_content_and_reproducibility():
    first = build()
    second = build()
    assert first == second
    with tarfile.open(OUTPUT, "r:gz") as archive:
        names = set(archive.getnames())
    assert REQUIRED <= names
    assert not any("/Tests/" in name or "/PropertyTests/" in name for name in names)
    assert not any(name.endswith((".unitypackage", ".tgz", ".bak2")) for name in names)
```

- [ ] **Step 2: Run the test and confirm builder-missing failure**

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
```

Expected: FAIL because the builder does not exist.

- [ ] **Step 3: Implement deterministic package staging**

Create `tools/phase0/build_upm_package.py` with these required operations:

```python
#!/usr/bin/env python3
import gzip
import json
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "unity_plugin/AreaTargetPlugin"
DIST = ROOT / "dist"
EXCLUDED_DIRS = {"Tests", "PropertyTests", "__pycache__"}
EXCLUDED_SUFFIXES = {".tgz", ".unitypackage", ".bak2", ".data1_bak"}


def ignored(_directory, names):
    return {
        name for name in names
        if name in EXCLUDED_DIRS or any(name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES)
    }


def add_tree(archive, root):
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root.parent)
        info = archive.gettarinfo(str(path), arcname=str(relative))
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        if path.is_file():
            with path.open("rb") as stream:
                archive.addfile(info, stream)
        else:
            archive.addfile(info)


def main():
    metadata = json.loads((SOURCE / "package.json").read_text())
    version = metadata["version"]
    DIST.mkdir(exist_ok=True)
    output = DIST / f"com.areatarget.tracking-{version}.tgz"
    with tempfile.TemporaryDirectory(prefix="area-target-upm-") as temp:
        package = Path(temp) / "package"
        shutil.copytree(SOURCE, package, ignore=ignored)
        for platform, filename in (
            ("iOS", "libvisual_localizer.a"),
            ("macOS", "libvisual_localizer.dylib"),
        ):
            source = ROOT / "unity_project/Assets/Plugins" / platform / filename
            if not source.is_file() or source.stat().st_size == 0:
                raise SystemExit(f"missing native artifact: {source}")
            target = package / "Runtime/Plugins" / platform / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            meta = source.with_suffix(source.suffix + ".meta")
            if meta.is_file():
                shutil.copy2(meta, target.with_suffix(target.suffix + ".meta"))
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    add_tree(archive, package)
    print(output)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Remove stale tracked archives**

```bash
git rm unity_plugin/AreaTargetPlugin/AreaTargetPlugin-1.2.0.unitypackage
git rm unity_plugin/AreaTargetPlugin/com.areatarget.tracking-1.2.0.tgz
```

Historical recovery remains available from Git history.

- [ ] **Step 5: Update package documentation**

Rewrite `BUILD_PACKAGE.md` so the primary command is:

```bash
python3 tools/phase0/build_upm_package.py
```

Document output path, inclusion/exclusion rules, and Unity clean-install validation. Keep `.unitypackage` export as a legacy optional path, not the release source of truth.

- [ ] **Step 6: Run package tests twice**

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
tar -tzf dist/com.areatarget.tracking-1.2.1.tgz | sort | sed -n '1,120p'
```

Expected: test PASS; required runtime sources and iOS/macOS libraries are visible; tests and old archives are absent.

- [ ] **Step 7: Commit Task 4**

```bash
git add tools/phase0/build_upm_package.py tests/phase0/test_upm_package.py unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_plugin/AreaTargetPlugin
git commit -m "build: generate reproducible UPM package"
```

## Task 5: Unified verification driver

**Requirements:** R0.6

**Files:**

- Create: `tools/phase0/verify.sh`
- Create: `tests/phase0/test_verify_driver.py`

- [ ] **Step 1: Add verification-driver contract tests**

Create `tests/phase0/test_verify_driver.py`:

```python
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phase0/verify.sh"


def test_list_exposes_required_checks():
    result = subprocess.run([str(VERIFY), "--list"], text=True, capture_output=True)
    assert result.returncode == 0
    for name in ("metadata", "python", "docker", "native", "ios-archive", "xcode", "unity", "upm"):
        assert name in result.stdout


def test_invalid_mode_fails():
    result = subprocess.run([str(VERIFY), "invalid"], text=True, capture_output=True)
    assert result.returncode != 0
    assert "usage" in (result.stdout + result.stderr).lower()
```

- [ ] **Step 2: Run tests and confirm the missing-driver failure**

```bash
python3 -m pytest tests/phase0/test_verify_driver.py -v
```

Expected: FAIL because `verify.sh` does not exist.

- [ ] **Step 3: Implement the fail-fast driver**

Create executable `tools/phase0/verify.sh` using this structure:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-local}"
CHECKS=(metadata hygiene python docker native ios-archive xcode unity upm)

if [[ "$MODE" == "--list" ]]; then
  printf '%s\n' "${CHECKS[@]}"
  exit 0
fi
if [[ "$MODE" != "local" && "$MODE" != "ci" ]]; then
  echo "usage: $0 [local|ci|--list]" >&2
  exit 2
fi

pass() { echo "PASS $1"; }
skip() { echo "SKIP $1: $2"; }
run() { local name="$1"; shift; echo "RUN  $name"; "$@"; pass "$name"; }

cd "$ROOT"
run metadata python3 tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json
run hygiene python3 -m pytest tests/phase0/test_repository_hygiene.py -q
run python python3 -m pytest tests/ -v --tb=short
run docker-config docker compose config --quiet
run docker-build docker build -t area-target-scanner-phase0 .
run native native_visual_localizer/build_macos.sh
run ios-archive tools/phase0/check_native_symbols.sh unity_project/Assets/Plugins/iOS/libvisual_localizer.a

if [[ "$MODE" == "ci" ]]; then
  skip xcode "generic iOS build is a required local gate"
  skip unity "Unity license is not configured in CI"
else
  run xcode tools/phase0/verify_ios_scanner.sh
  run unity tools/phase0/validate_unity_package.sh
fi

run upm python3 tools/phase0/build_upm_package.py
run upm-content python3 -m pytest tests/phase0/test_upm_package.py -q
```

The script must preserve the first failing command's non-zero exit code.

- [ ] **Step 4: Run driver contract tests**

```bash
python3 -m pytest tests/phase0/test_verify_driver.py -v
tools/phase0/verify.sh --list
```

Expected: tests PASS and exactly the required check names are listed.

- [ ] **Step 5: Commit Task 5**

```bash
git add tools/phase0/verify.sh tests/phase0/test_verify_driver.py docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "build: add phase 0 verification driver"
```

## Task 6: Xcode and Unity local gates

**Requirements:** R0.5, R0.6, R0.7

**Files:**

- Create: `tools/phase0/verify_ios_scanner.sh`
- Create: `tools/phase0/validate_unity_package.sh`
- Modify: `TEST_PLAN.md`

- [ ] **Step 1: Implement generic iOS scanner build verification**

Create executable `tools/phase0/verify_ios_scanner.sh`:

```bash
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
```

- [ ] **Step 2: Implement Unity tests plus clean UPM install**

Create executable `tools/phase0/validate_unity_package.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNITY_PATH="${UNITY_PATH:-/Applications/Unity/Hub/Editor/6000.3.11f1/Unity.app/Contents/MacOS/Unity}"
RESULTS="$ROOT/phase0-results"
PROJECT="/tmp/area-target-phase0-unity"

[[ -x "$UNITY_PATH" ]] || { echo "Unity not found: $UNITY_PATH" >&2; exit 2; }
mkdir -p "$RESULTS"

"$UNITY_PATH" -batchmode -nographics \
  -projectPath "$ROOT/unity_project" \
  -runTests -testPlatform EditMode \
  -testResults "$RESULTS/unity-editmode.xml" \
  -logFile "$RESULTS/unity-editmode.log"

python3 - "$RESULTS/unity-editmode.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
total = int(root.attrib.get("total", "0"))
failed = int(root.attrib.get("failed", "1"))
if total <= 0 or failed != 0:
    raise SystemExit(f"Unity tests invalid: total={total}, failed={failed}")
PY

python3 "$ROOT/tools/phase0/build_upm_package.py"
VERSION="$(python3 "$ROOT/tools/phase0/check_package_metadata.py" "$ROOT/unity_plugin/AreaTargetPlugin/package.json")"
PACKAGE="$ROOT/dist/com.areatarget.tracking-$VERSION.tgz"

rm -rf "$PROJECT"
"$UNITY_PATH" -batchmode -nographics -createProject "$PROJECT" -quit -logFile "$RESULTS/unity-create.log"

python3 - "$PROJECT/Packages/manifest.json" "$PACKAGE" <<'PY'
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
```

- [ ] **Step 3: Document exact local gates in `TEST_PLAN.md`**

Add the two commands:

```bash
tools/phase0/verify_ios_scanner.sh
tools/phase0/validate_unity_package.sh
```

State that simulator execution does not certify LiDAR scanning and that Unity test XML must contain at least one test with zero failures.

- [ ] **Step 4: Run the iOS scanner build**

```bash
tools/phase0/verify_ios_scanner.sh
```

Expected: `** BUILD SUCCEEDED **` in `phase0-results/xcode/build.log`.

- [ ] **Step 5: Run Unity tests and clean package install**

```bash
tools/phase0/validate_unity_package.sh
```

Expected: EditMode XML reports non-zero tests and zero failures; temporary project compiles without `error CS` or package resolution errors.

- [ ] **Step 6: Commit Task 6**

```bash
git add tools/phase0/verify_ios_scanner.sh tools/phase0/validate_unity_package.sh TEST_PLAN.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "test: add iOS and Unity baseline gates"
```

## Task 7: Expand CI to the Phase 0 baseline

**Requirements:** R0.7

**Files:**

- Modify: `.github/workflows/ci.yml`
- Modify: `requirements-dev.txt`

- [ ] **Step 1: Replace the sampled Python test command**

The Linux Python job must install all three requirement sets and run:

```yaml
- name: Install Python dependencies
  run: |
    python -m pip install --upgrade pip
    pip install -r requirements.txt
    pip install -r web_service/requirements.txt
    pip install -r requirements-dev.txt

- name: Run Phase 0 tests
  run: python -m pytest tests/ -v --tb=short

- name: Validate package metadata
  run: python tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json

- name: Build and inspect UPM package
  run: |
    python tools/phase0/build_upm_package.py
    python -m pytest tests/phase0/test_upm_package.py -v
```

- [ ] **Step 2: Add Docker configuration validation before image build**

```yaml
- name: Validate Docker Compose
  run: docker compose config --quiet

- name: Build web service image
  run: docker build -t area-target-scanner-web-service-ci .
```

- [ ] **Step 3: Add a macOS native job**

```yaml
native-macos:
  runs-on: macos-14
  steps:
    - uses: actions/checkout@v4
    - name: Install native dependencies
      run: brew install cmake opencv
    - name: Build and verify native library
      run: native_visual_localizer/build_macos.sh
    - name: Verify iOS archive contract
      run: tools/phase0/check_native_symbols.sh unity_project/Assets/Plugins/iOS/libvisual_localizer.a
```

- [ ] **Step 4: Document the Unity local-gate exception in workflow comments**

Add a comment explaining that Unity EditMode remains a required local release gate until repository secrets contain a valid Unity license. Do not add a fake passing Unity job.

- [ ] **Step 5: Add the workflow parser dependency**

Add to `requirements-dev.txt`:

```text
PyYAML>=6.0,<7
```

- [ ] **Step 6: Validate workflow syntax and local CI mode**

```bash
python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/ci.yml"))'
tools/phase0/verify.sh ci
```

Expected: YAML parses; all CI-mode checks pass and Xcode/Unity are explicitly reported as `SKIP`.

- [ ] **Step 7: Commit Task 7**

```bash
git add .github/workflows/ci.yml requirements-dev.txt docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "ci: enforce phase 0 baseline checks"
```

## Task 8: Baseline documentation and support claims

**Requirements:** R0.8

**Files:**

- Modify: `README.md`
- Modify: `unity_plugin/AreaTargetPlugin/README.md`
- Modify: `unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md`

- [ ] **Step 1: Add an explicit Phase 0 support table**

In the root README and package README, state:

| Target | Phase 0 status |
|---|---|
| macOS development build | Verified baseline |
| iOS scanner generic-device build | Verified baseline |
| iOS localizer archive | Static symbol verification only |
| Rokid AR Studio | Planned for Phase 2; unsupported in Phase 0 |
| Android ARM64 | Planned for Phase 2; unsupported in Phase 0 |
| Windows/Linux runtime | Unsupported; empty placeholders removed |

- [ ] **Step 2: Correct build and package instructions**

Document these canonical commands:

```bash
tools/phase0/verify.sh local
python3 tools/phase0/build_upm_package.py
tools/phase0/validate_unity_package.sh
```

Remove instructions that point to tracked `1.2.0` archives as the current release.

- [ ] **Step 3: Check documentation claims**

```bash
rg -n "supports.*Android|Windows|Linux|Rokid|支持.*Android|支持.*Windows|支持.*Linux|支持.*Rokid" README.md unity_plugin/AreaTargetPlugin/README.md
```

Expected: every remaining match is qualified as unsupported/planned or backed by Phase 0 evidence.

- [ ] **Step 4: Commit Task 8**

```bash
git add README.md unity_plugin/AreaTargetPlugin/README.md unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "docs: document phase 0 support baseline"
```

## Task 9: Full clean-checkout acceptance

**Requirements:** all requirements and acceptance criteria

**Files:**

- Create: `docs/phase-0-validation.md`
- Update: this `tasks.md` as checks complete

- [ ] **Step 1: Run all fast tests in the working checkout**

```bash
python3 -m pytest tests/ -v --tb=short
docker compose config --quiet
python3 tools/phase0/build_upm_package.py
python3 -m pytest tests/phase0 -v
```

Expected: all commands return zero.

- [ ] **Step 2: Run the complete local gate**

```bash
tools/phase0/verify.sh local | tee phase0-results/phase0-local.log
```

Expected: every required row is `PASS`; no required row is `SKIP`.

- [ ] **Step 3: Verify reproducibility in a clean worktree**

```bash
git worktree add /tmp/area-target-phase0-clean HEAD
cd /tmp/area-target-phase0-clean
git submodule update --init --recursive
tools/phase0/verify.sh local | tee phase0-results/phase0-clean.log
```

Expected: full gate PASS from the clean worktree.

- [ ] **Step 4: Create the validation record from actual versions and results**

Run these commands, then create `docs/phase-0-validation.md` using their literal outputs and the actual PASS/FAIL/SKIP rows from both logs:

```bash
git rev-parse HEAD
sw_vers
xcodebuild -version
python3 --version
docker --version
docker compose version
"$UNITY_PATH" -version
cmake --version
```

Copy only the result summary, not full scan data or private device content.

- [ ] **Step 5: Confirm clean source state**

```bash
git status --short
git diff --check
```

Expected: no unexpected source changes. `dist/`, `build/`, `phase0-results/`, and temporary validation projects remain ignored or outside the repository.

- [ ] **Step 6: Commit the final validation record and completed task state**

```bash
git add docs/phase-0-validation.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "chore: validate reproducible v1.2.1 baseline"
```

- [ ] **Step 7: Remove the temporary clean worktree**

Return to the primary worktree, then run:

```bash
git worktree remove /tmp/area-target-phase0-clean
```

Expected: the temporary worktree is removed and the primary worktree remains unchanged.

- [ ] **Step 8: Verify acceptance before external release actions**

```bash
git status --short --branch
git log --oneline --decorate -10
test "$(python3 tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json)" = "1.2.1"
```

Expected: clean branch, documented Phase 0 commits, and canonical version `1.2.1`.

Do not push, tag, create a GitHub Release, or merge to `main` without explicit user authorization after this point.
