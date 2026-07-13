import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase1/validate_scan_contract.py"
FIXTURE = ROOT / "tests/fixtures/phase1/coordinate-contract-v1.json"


def run_checker(path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), str(path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


def write_contract(tmp_path: Path, mutate) -> Path:
    data = json.loads(FIXTURE.read_text())
    mutate(data)
    path = tmp_path / "coordinate-contract.json"
    path.write_text(json.dumps(data))
    return path


def test_contract_fixture_is_valid():
    result = run_checker(FIXTURE)
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output["schemaVersion"] == 1
    assert output["unityWorldFromScan"] == [
        1.0,
        0.0,
        0.0,
        5.0,
        0.0,
        1.0,
        0.0,
        7.0,
        0.0,
        0.0,
        1.0,
        9.0,
        0.0,
        0.0,
        0.0,
        1.0,
    ]


def test_matrix_with_wrong_length_is_rejected(tmp_path):
    path = write_contract(tmp_path, lambda data: data["cameraFromScan"].pop())
    result = run_checker(path)
    assert result.returncode != 0
    assert "cameraFromScan must contain 16 values" in result.stderr


def test_unknown_image_orientation_is_rejected(tmp_path):
    path = write_contract(
        tmp_path, lambda data: data.__setitem__("imageOrientation", "diagonal")
    )
    result = run_checker(path)
    assert result.returncode != 0
    assert "imageOrientation" in result.stderr


def test_nonpositive_intrinsics_are_rejected(tmp_path):
    path = write_contract(
        tmp_path, lambda data: data["intrinsics"].__setitem__("fx", 0.0)
    )
    result = run_checker(path)
    assert result.returncode != 0
    assert "intrinsics.fx" in result.stderr


def test_wrong_composed_pose_is_rejected(tmp_path):
    path = write_contract(
        tmp_path,
        lambda data: data["expectedUnityWorldFromScan"].__setitem__(3, 999.0),
    )
    result = run_checker(path)
    assert result.returncode != 0
    assert "T_U_S must equal T_U_C × T_C_S" in result.stderr
