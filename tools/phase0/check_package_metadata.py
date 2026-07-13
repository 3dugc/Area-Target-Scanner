#!/usr/bin/env python3
import json
import sys
from pathlib import Path

EXPECTED_VERSION = "1.3.0"
EXPECTED_DEPENDENCIES = {
    "com.unity.xr.arfoundation": "6.0.0",
    "com.gilzoide.sqlite-net": "1.3.2",
}


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <package.json>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    try:
        data = json.loads(path.read_text(), object_pairs_hook=reject_duplicates)
        if data.get("version") != EXPECTED_VERSION:
            raise ValueError(f"version must be {EXPECTED_VERSION}")
        dependencies = data.get("dependencies", {})
        for name, version in EXPECTED_DEPENDENCIES.items():
            if dependencies.get(name) != version:
                raise ValueError(f"{name} must be {version}")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"metadata error: {exc}", file=sys.stderr)
        return 2
    print(data["version"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
