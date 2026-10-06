import importlib.util
from pathlib import Path
import subprocess

import pytest

HELPER = Path(__file__).resolve().parents[1] / "tools/opencv5/run_regression.py"


def runner():
    spec = importlib.util.spec_from_file_location("opencv5_regression", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_success_exit_without_complete_junit_is_rejected(tmp_path, monkeypatch):
    module = runner()
    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0))
    with pytest.raises(RuntimeError, match="complete JUnit"):
        module.run_group("pipeline", [], tmp_path, {})


@pytest.mark.parametrize("attributes", [
    'tests="2" failures="1" errors="0" skipped="0"',
    'tests="2" failures="0" errors="1" skipped="0"',
    'tests="0" failures="0" errors="0" skipped="0"',
])
def test_failed_or_empty_junit_is_rejected(tmp_path, attributes):
    report = tmp_path / "report.xml"
    report.write_text(f"<testsuites><testsuite {attributes}/></testsuites>")
    with pytest.raises(RuntimeError):
        runner().validate_junit(report)


def test_complete_junit_records_passes_and_skips(tmp_path):
    report = tmp_path / "report.xml"
    report.write_text('<testsuites><testsuite tests="3" failures="0" errors="0" skipped="1"/></testsuites>')
    assert runner().validate_junit(report) == {"passed": 2, "skipped": 1}
