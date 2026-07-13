#!/usr/bin/env python3
"""Validate the versioned cross-language localization coordinate fixture."""

import json
import math
import sys
from pathlib import Path
from typing import Any


ALLOWED_ORIENTATIONS = {
    "landscapeLeft",
    "landscapeRight",
    "portrait",
    "portraitUpsideDown",
}
EXPECTED_SCHEMA_VERSION = 1
EXPECTED_COORDINATE_SYSTEM = "arkit-world"
EXPECTED_UNITS = "meters"
EXPECTED_SCAN_POSE_LAYOUT = "arkit-column-major"
EXPECTED_NATIVE_POSE_LAYOUT = "row-major"
MATRIX_SIZE = 4
MATRIX_VALUE_COUNT = MATRIX_SIZE * MATRIX_SIZE
TOLERANCE = 1e-5


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def require_finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a finite number")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{name} must be a finite number")
    return number


def require_positive_integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value


def matrix_from_row_major(value: Any, name: str) -> list[list[float]]:
    if not isinstance(value, list) or len(value) != MATRIX_VALUE_COUNT:
        raise ValueError(f"{name} must contain 16 values")
    numbers = [require_finite_number(item, f"{name}[{index}]") for index, item in enumerate(value)]
    return [numbers[index : index + MATRIX_SIZE] for index in range(0, MATRIX_VALUE_COUNT, MATRIX_SIZE)]


def multiply(left: list[list[float]], right: list[list[float]]) -> list[list[float]]:
    return [
        [
            sum(left[row][index] * right[index][column] for index in range(MATRIX_SIZE))
            for column in range(MATRIX_SIZE)
        ]
        for row in range(MATRIX_SIZE)
    ]


def flatten_row_major(matrix: list[list[float]]) -> list[float]:
    return [value for row in matrix for value in row]


def validate_contract(data: Any) -> list[float]:
    contract = require_mapping(data, "contract")

    if contract.get("schemaVersion") != EXPECTED_SCHEMA_VERSION:
        raise ValueError(f"schemaVersion must be {EXPECTED_SCHEMA_VERSION}")
    if contract.get("coordinateSystem") != EXPECTED_COORDINATE_SYSTEM:
        raise ValueError(f"coordinateSystem must be {EXPECTED_COORDINATE_SYSTEM}")
    if contract.get("units") != EXPECTED_UNITS:
        raise ValueError(f"units must be {EXPECTED_UNITS}")
    if contract.get("scanPoseLayout") != EXPECTED_SCAN_POSE_LAYOUT:
        raise ValueError(f"scanPoseLayout must be {EXPECTED_SCAN_POSE_LAYOUT}")
    if contract.get("nativePoseLayout") != EXPECTED_NATIVE_POSE_LAYOUT:
        raise ValueError(f"nativePoseLayout must be {EXPECTED_NATIVE_POSE_LAYOUT}")

    orientation = contract.get("imageOrientation")
    if orientation not in ALLOWED_ORIENTATIONS:
        allowed = ", ".join(sorted(ALLOWED_ORIENTATIONS))
        raise ValueError(f"imageOrientation must be one of: {allowed}")

    image = require_mapping(contract.get("image"), "image")
    width = require_positive_integer(image.get("width"), "image.width")
    height = require_positive_integer(image.get("height"), "image.height")

    intrinsics = require_mapping(contract.get("intrinsics"), "intrinsics")
    fx = require_finite_number(intrinsics.get("fx"), "intrinsics.fx")
    fy = require_finite_number(intrinsics.get("fy"), "intrinsics.fy")
    cx = require_finite_number(intrinsics.get("cx"), "intrinsics.cx")
    cy = require_finite_number(intrinsics.get("cy"), "intrinsics.cy")
    if fx <= 0:
        raise ValueError("intrinsics.fx must be positive")
    if fy <= 0:
        raise ValueError("intrinsics.fy must be positive")
    if not 0 <= cx <= width:
        raise ValueError("intrinsics.cx must be inside image bounds")
    if not 0 <= cy <= height:
        raise ValueError("intrinsics.cy must be inside image bounds")

    unity_world_from_camera = matrix_from_row_major(
        contract.get("unityWorldFromCamera"), "unityWorldFromCamera"
    )
    camera_from_scan = matrix_from_row_major(
        contract.get("cameraFromScan"), "cameraFromScan"
    )
    expected_unity_world_from_scan = matrix_from_row_major(
        contract.get("expectedUnityWorldFromScan"), "expectedUnityWorldFromScan"
    )

    actual_unity_world_from_scan = multiply(unity_world_from_camera, camera_from_scan)
    for row in range(MATRIX_SIZE):
        for column in range(MATRIX_SIZE):
            if not math.isclose(
                actual_unity_world_from_scan[row][column],
                expected_unity_world_from_scan[row][column],
                abs_tol=TOLERANCE,
            ):
                raise ValueError("T_U_S must equal T_U_C × T_C_S")

    return flatten_row_major(actual_unity_world_from_scan)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <coordinate-contract.json>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    try:
        contract = json.loads(path.read_text())
        unity_world_from_scan = validate_contract(contract)
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"contract error: {error}", file=sys.stderr)
        return 2

    print(
        json.dumps(
            {
                "schemaVersion": EXPECTED_SCHEMA_VERSION,
                "unityWorldFromScan": unity_world_from_scan,
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
