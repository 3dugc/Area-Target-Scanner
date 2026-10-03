#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-local}"
CHECKS=(
  contract
  python-pipeline
  unity-editmode
  native-macos
  native-ios
  upm-content
  clean-upm-install
  unity-ios-export
  generic-xcode-build
  device-discovery
  device-smoke
)
CI_UNITY_SKIP_REASON="GitHub-hosted CI does not configure Unity or iOS signing"

if [[ "$MODE" == "--list" ]]; then
  printf '%s\n' "${CHECKS[@]}"
  exit 0
fi

if [[ "$MODE" != "ci" && "$MODE" != "local" && "$MODE" != "device" ]]; then
  echo "usage: $0 [ci|local|device|--list]" >&2
  exit 2
fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON="$PYTHON_BIN"
elif [[ -x "$ROOT/venv/bin/python" ]]; then
  PYTHON="$ROOT/venv/bin/python"
else
  PYTHON="python3"
fi

BASH_BIN="${BASH_BIN:-bash}"
UNITY_PATH="${UNITY_PATH:-/Applications/Unity/Hub/Editor/6000.4.6f1/Unity.app/Contents/MacOS/Unity}"
PASSED=0
FAILED=0
SKIPPED=0
FAILED_STEPS=()

pass() {
  echo "PASS $1"
  ((PASSED += 1))
}

fail() {
  local name="$1"
  shift
  echo "FAIL $name: $*" >&2
  FAILED_STEPS+=("$name")
  ((FAILED += 1))
}

skip() {
  echo "SKIP $1: $2"
  ((SKIPPED += 1))
}

run() {
  local name="$1"
  shift
  echo "RUN  $name"
  if "$@"; then
    pass "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

run_non_unity_checks() {
  run contract "$PYTHON" tools/phase1/validate_scan_contract.py \
    tests/fixtures/phase1/coordinate-contract-v1.json
  run python-pipeline "$PYTHON" -m pytest --import-mode=importlib \
    tests/phase1 tests/ -v --tb=short
  run native-macos "$BASH_BIN" native_visual_localizer/build_macos.sh
  run native-ios "$BASH_BIN" tools/phase0/check_native_symbols.sh \
    unity_project/Assets/Plugins/iOS/libvisual_localizer.a
  run upm-content "$PYTHON" -m pytest tests/phase0/test_upm_package.py -v
}

run_unity_editmode_and_clean_install() {
  if [[ ! -x "$UNITY_PATH" ]]; then
    fail unity-editmode "Unity executable not found: $UNITY_PATH"
    fail clean-upm-install "Unity executable not found: $UNITY_PATH"
    return
  fi

  echo "RUN  unity-editmode + clean-upm-install"
  if UNITY_PATH="$UNITY_PATH" "$BASH_BIN" tools/phase0/validate_unity_package.sh; then
    pass unity-editmode
    pass clean-upm-install
  else
    fail unity-editmode "tools/phase0/validate_unity_package.sh failed"
    fail clean-upm-install "tools/phase0/validate_unity_package.sh failed"
  fi
}

run_unity_ios_export_and_generic_xcode_build() {
  if [[ ! -x "$UNITY_PATH" ]]; then
    fail unity-ios-export "Unity executable not found: $UNITY_PATH"
    fail generic-xcode-build "Unity executable not found: $UNITY_PATH"
    return
  fi

  if ! command -v xcodebuild >/dev/null 2>&1; then
    fail unity-ios-export "xcodebuild not found on PATH"
    fail generic-xcode-build "xcodebuild not found on PATH"
    return
  fi

  echo "RUN  unity-ios-export + generic-xcode-build"
  if UNITY_PATH="$UNITY_PATH" PYTHON_BIN="$PYTHON" \
    "$BASH_BIN" tools/phase1/validate_ios_upm_build.sh; then
    pass unity-ios-export
    pass generic-xcode-build
  else
    fail unity-ios-export "tools/phase1/validate_ios_upm_build.sh failed"
    fail generic-xcode-build "tools/phase1/validate_ios_upm_build.sh failed"
  fi
}

run_device_discovery() {
  if ! command -v xcrun >/dev/null 2>&1; then
    fail device-discovery "xcrun not found; run: xcrun xctrace list devices"
    return 1
  fi

  local listing
  if ! listing="$(xcrun xctrace list devices 2>&1)"; then
    fail device-discovery "xcrun xctrace list devices failed"
    printf '%s\n' "$listing" >&2
    return 1
  fi

  local physical_devices
  physical_devices="$(printf '%s\n' "$listing" | awk '/^== Simulators ==/{exit} {print}')"
  local iphone_line
  local ipad_line
  iphone_line="$(printf '%s\n' "$physical_devices" | grep -Ei 'iPhone' | head -n 1 || true)"
  ipad_line="$(printf '%s\n' "$physical_devices" | grep -Ei 'iPad' | head -n 1 || true)"

  if [[ -z "$iphone_line" || -z "$ipad_line" ]]; then
    fail device-discovery "requires one USB-visible iPhone and one USB-visible iPad; run: xcrun xctrace list devices"
    return 1
  fi

  PHASE1_IPHONE_DEVICE="$iphone_line"
  PHASE1_IPAD_DEVICE="$ipad_line"
  export PHASE1_IPHONE_DEVICE PHASE1_IPAD_DEVICE
  pass device-discovery
  return 0
}

run_device_smoke() {
  if [[ -z "${PHASE1_DEVICE_SMOKE_COMMAND:-}" ]]; then
    fail device-smoke "not configured; task 9 must provide a signed deployment and localization smoke command"
    return
  fi

  echo "RUN  device-smoke"
  if "$BASH_BIN" -lc "$PHASE1_DEVICE_SMOKE_COMMAND"; then
    pass device-smoke
  else
    fail device-smoke "command failed: $PHASE1_DEVICE_SMOKE_COMMAND"
  fi
}

cd "$ROOT"
run_non_unity_checks

case "$MODE" in
  ci)
    skip unity-editmode "$CI_UNITY_SKIP_REASON"
    skip clean-upm-install "$CI_UNITY_SKIP_REASON"
    skip unity-ios-export "$CI_UNITY_SKIP_REASON"
    skip generic-xcode-build "$CI_UNITY_SKIP_REASON"
    skip device-discovery "$CI_UNITY_SKIP_REASON"
    skip device-smoke "$CI_UNITY_SKIP_REASON"
    ;;
  local)
    run_unity_editmode_and_clean_install
    run_unity_ios_export_and_generic_xcode_build
    skip device-discovery "device mode was not requested"
    skip device-smoke "device mode was not requested"
    ;;
  device)
    run_unity_editmode_and_clean_install
    run_unity_ios_export_and_generic_xcode_build
    if run_device_discovery; then
      if (( FAILED == 0 )); then
        run_device_smoke
      else
        skip device-smoke "required local release gates did not pass"
      fi
    else
      skip device-smoke "device discovery did not pass"
    fi
    ;;
esac

echo "SUMMARY PASS=$PASSED FAIL=$FAILED SKIP=$SKIPPED"
if (( FAILED > 0 )); then
  echo "FAILED STEPS: ${FAILED_STEPS[*]}" >&2
  exit 1
fi
