import os
import stat
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phase1/verify.sh"


def write_fake_command(path: Path, name: str) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "command_name=\"${0##*/}\"\n"
        "if [ -n \"${VERIFY_FAKE_LOG:-}\" ]; then\n"
        "  printf '%s %s\\n' \"$command_name\" \"$*\" >> \"$VERIFY_FAKE_LOG\"\n"
        "fi\n"
        "if [ \"${VERIFY_FAIL_COMMAND:-}\" = \"$command_name\" ]; then\n"
        "  exit 23\n"
        "fi\n"
        "if [ \"$command_name\" = \"xcrun\" ] && [ \"${1:-}\" = \"xctrace\" ]; then\n"
        "  printf '%s\\n' \"${VERIFY_XCTRACE_OUTPUT:-== Devices ==}\"\n"
        "fi\n"
        "exit 0\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def fake_environment(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("bash", "python3", "xcodebuild", "xcrun"):
        write_fake_command(bin_dir / name, name)

    unity = bin_dir / "Unity"
    write_fake_command(unity, "Unity")
    log = tmp_path / "commands.log"
    environment = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "PYTHON_BIN": "python3",
        "BASH_BIN": "bash",
        "UNITY_PATH": str(unity),
        "VERIFY_FAKE_LOG": str(log),
    }
    return environment, bin_dir, log


def run_verify(mode: str, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(VERIFY), mode],
        cwd=ROOT,
        text=True,
        capture_output=True,
        env=environment,
    )


def output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def test_ci_runs_non_unity_checks_and_reports_required_skips(fake_environment):
    environment, _, log = fake_environment

    result = run_verify("ci", environment)

    assert result.returncode == 0, output(result)
    report = output(result)
    for check in ("contract", "python-pipeline", "native-macos", "native-ios", "upm-content"):
        assert f"PASS {check}" in report
    for check in (
        "unity-editmode",
        "clean-upm-install",
        "unity-ios-export",
        "generic-xcode-build",
        "device-discovery",
        "device-smoke",
    ):
        assert f"SKIP {check}: GitHub-hosted CI" in report
    commands = log.read_text()
    assert "python3" in commands
    assert "bash" in commands
    assert "--import-mode=importlib" in commands


def test_local_fails_when_unity_is_missing(fake_environment, tmp_path):
    environment, _, _ = fake_environment
    environment["UNITY_PATH"] = str(tmp_path / "missing-Unity")

    result = run_verify("local", environment)

    assert result.returncode != 0
    report = output(result)
    assert "FAIL unity-editmode" in report
    assert "Unity executable not found" in report


def test_local_fails_when_xcodebuild_is_missing(fake_environment):
    environment, bin_dir, _ = fake_environment
    (bin_dir / "xcodebuild").unlink()
    environment["PATH"] = str(bin_dir)

    result = run_verify("local", environment)

    assert result.returncode != 0
    report = output(result)
    assert "FAIL generic-xcode-build" in report
    assert "xcodebuild not found" in report


def test_device_fails_with_discovery_command_when_iPhone_or_iPad_is_missing(fake_environment):
    environment, _, _ = fake_environment
    environment["VERIFY_XCTRACE_OUTPUT"] = "== Devices ==\\nTest Mac (macOS)"

    result = run_verify("device", environment)

    assert result.returncode != 0
    report = output(result)
    assert "FAIL device-discovery" in report
    assert "xcrun xctrace list devices" in report


def test_device_does_not_run_smoke_when_a_local_release_gate_failed(fake_environment):
    environment, _, _ = fake_environment
    environment["VERIFY_FAIL_COMMAND"] = "bash"
    environment["VERIFY_XCTRACE_OUTPUT"] = (
        "== Devices ==\n"
        "iPhone Test (26.3) (00000000-0000-0000-0000-000000000001)\n"
        "iPad Test (26.3) (00000000-0000-0000-0000-000000000002)"
    )
    environment["PHASE1_DEVICE_SMOKE_COMMAND"] = "echo deployment-must-not-run"

    result = run_verify("device", environment)

    assert result.returncode != 0
    assert "SKIP device-smoke: required local release gates did not pass" in output(result)


def test_child_check_failure_keeps_failed_step_name(fake_environment):
    environment, _, _ = fake_environment
    environment["VERIFY_FAIL_COMMAND"] = "bash"

    result = run_verify("ci", environment)

    assert result.returncode != 0
    assert "FAIL native-macos" in output(result)
