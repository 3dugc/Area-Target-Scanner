import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phase0/verify.sh"


def test_list_exposes_required_checks():
    result = subprocess.run([str(VERIFY), "--list"], text=True, capture_output=True)
    assert result.returncode == 0
    for name in (
        "metadata",
        "python",
        "docker",
        "native",
        "ios-archive",
        "xcode",
        "unity",
        "upm",
    ):
        assert name in result.stdout


def test_invalid_mode_fails():
    result = subprocess.run([str(VERIFY), "invalid"], text=True, capture_output=True)
    assert result.returncode != 0
    assert "usage" in (result.stdout + result.stderr).lower()
