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

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON="$PYTHON_BIN"
elif [[ -x "$ROOT/venv/bin/python" ]]; then
  PYTHON="$ROOT/venv/bin/python"
else
  PYTHON="python3"
fi

pass() { echo "PASS $1"; }
skip() { echo "SKIP $1: $2"; }
run() {
  local name="$1"
  shift
  echo "RUN  $name"
  "$@"
  pass "$name"
}

cd "$ROOT"
run metadata "$PYTHON" tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json
run hygiene "$PYTHON" -m pytest tests/phase0/test_repository_hygiene.py -q
run python "$PYTHON" -m pytest tests/ -v --tb=short
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

run upm "$PYTHON" tools/phase0/build_upm_package.py
run upm-content "$PYTHON" -m pytest tests/phase0/test_upm_package.py -q
