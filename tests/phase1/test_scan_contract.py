import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase1/validate_scan_contract.py"
FIXTURE = ROOT / "tests/fixtures/phase1/coordinate-contract-v1.json"


def run_checker(*args: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), *(str(arg) for arg in args)],
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


def valid_scan_manifest() -> dict:
    transform = [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
    ]
    return {
        "schemaVersion": 1,
        "coordinateSystem": "arkit-world",
        "matrixLayout": "arkit-column-major",
        "units": "meters",
        "frames": [
            {
                "index": 0,
                "timestamp": 1.0,
                "imageFile": "images/frame_0000.jpg",
                "transform": transform,
                "imageOrientation": "landscapeRight",
                "image": {"width": 640, "height": 480},
                "intrinsics": {"fx": 500.0, "fy": 510.0, "cx": 320.0, "cy": 240.0},
            },
            {
                "index": 1,
                "timestamp": 1.5,
                "imageFile": "images/frame_0001.jpg",
                "transform": transform,
                "imageOrientation": "landscapeRight",
                "image": {"width": 640, "height": 480},
                "intrinsics": {"fx": 500.0, "fy": 510.0, "cx": 320.0, "cy": 240.0},
            },
        ],
    }


def write_scan_manifest(tmp_path: Path, manifest: dict) -> Path:
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    return path


def write_mutated_scan_manifest(tmp_path: Path, mutate) -> Path:
    manifest = valid_scan_manifest()
    mutate(manifest)
    return write_scan_manifest(tmp_path, manifest)


def test_scan_manifest_is_valid(tmp_path):
    result = run_checker("--scan-manifest", write_scan_manifest(tmp_path, valid_scan_manifest()))
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output == {
        "schemaVersion": 1,
        "frameCount": 2,
        "orientationCounts": {"landscapeRight": 2},
    }


def test_scan_manifest_rejects_duplicate_image_filename(tmp_path):
    path = write_mutated_scan_manifest(
        tmp_path,
        lambda manifest: manifest["frames"][1].__setitem__(
            "imageFile", manifest["frames"][0]["imageFile"]
        ),
    )
    result = run_checker("--scan-manifest", path)
    assert result.returncode != 0
    assert "imageFile must be unique" in result.stderr


def test_scan_manifest_rejects_missing_image_orientation(tmp_path):
    path = write_mutated_scan_manifest(
        tmp_path, lambda manifest: manifest["frames"][0].pop("imageOrientation")
    )
    result = run_checker("--scan-manifest", path)
    assert result.returncode != 0
    assert "imageOrientation" in result.stderr


def test_scan_manifest_rejects_nonincreasing_timestamp(tmp_path):
    path = write_mutated_scan_manifest(
        tmp_path, lambda manifest: manifest["frames"][1].__setitem__("timestamp", 1.0)
    )
    result = run_checker("--scan-manifest", path)
    assert result.returncode != 0
    assert "timestamp must be strictly increasing" in result.stderr


def test_scan_manifest_rejects_non_16_value_transform(tmp_path):
    path = write_mutated_scan_manifest(
        tmp_path, lambda manifest: manifest["frames"][0]["transform"].pop()
    )
    result = run_checker("--scan-manifest", path)
    assert result.returncode != 0
    assert "transform must contain 16 values" in result.stderr


def test_scan_manifest_rejects_intrinsics_outside_image_bounds(tmp_path):
    path = write_mutated_scan_manifest(
        tmp_path,
        lambda manifest: manifest["frames"][0]["intrinsics"].__setitem__("cx", 641.0),
    )
    result = run_checker("--scan-manifest", path)
    assert result.returncode != 0
    assert "intrinsics.cx must be inside image bounds" in result.stderr


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
