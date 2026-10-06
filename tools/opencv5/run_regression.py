#!/usr/bin/env python3
"""Run all regressions in two processes and reject silent native early exits.

Open3D Poisson can exit(0) before pytest finishes on this macOS baseline.
Isolate its mesh properties and require a fresh, complete JUnit report for
each group. A process return code alone is not acceptance evidence.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def validate_junit(path):
    if not Path(path).is_file():
        raise RuntimeError("pytest did not write a complete JUnit report: " + str(path))
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    totals = {field: sum(int(suite.get(field, "0")) for suite in suites)
              for field in ("tests", "failures", "errors", "skipped")}
    if totals["failures"] or totals["errors"] or totals["tests"] <= totals["skipped"]:
        raise RuntimeError("pytest JUnit report has failures, errors or no executed tests: " + str(path))
    return {"passed": totals["tests"] - totals["skipped"], "skipped": totals["skipped"]}


def run_group(name, paths, results, environment):
    report = Path(results) / f"{name}.xml"
    command = [sys.executable, "-m", "pytest", "--import-mode=importlib",
               *paths, "-v", "--tb=short", f"--junitxml={report}"]
    result = subprocess.run(command, env=environment)
    if result.returncode:
        raise RuntimeError(f"{name}: pytest exited with status {result.returncode}")
    totals = validate_junit(report)
    print(f"PASS {name}: {totals['passed']} passed, {totals['skipped']} skipped; complete JUnit", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--import-mode", choices=["importlib"], default="importlib")
    parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="opencv5-regression-") as results:
        run_group("pipeline", ["tests/phase1", "tests/", "--ignore=tests/test_mesh_properties.py"],
                  results, dict(os.environ))
        mesh_environment = {**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
                            "VECLIB_MAXIMUM_THREADS": "1"}
        run_group("mesh", ["tests/test_mesh_properties.py"], results, mesh_environment)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ET.ParseError, ValueError) as error:
        raise SystemExit(str(error))
