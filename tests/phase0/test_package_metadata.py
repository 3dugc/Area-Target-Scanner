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
