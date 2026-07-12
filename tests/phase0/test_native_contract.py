import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase0/check_native_symbols.sh"
IOS_LIB = ROOT / "unity_project/Assets/Plugins/iOS/libvisual_localizer.a"


@pytest.mark.skipif(
    sys.platform != "darwin",
    reason="iOS Mach-O archive contract is verified by the required macOS CI job",
)
def test_ios_archive_matches_native_contract():
    result = subprocess.run([str(CHECKER), str(IOS_LIB)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_empty_library_is_rejected(tmp_path):
    empty = tmp_path / "empty.so"
    empty.touch()
    result = subprocess.run([str(CHECKER), str(empty)], text=True, capture_output=True)
    assert result.returncode != 0
    assert "empty" in (result.stdout + result.stderr).lower()
