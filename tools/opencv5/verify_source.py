#!/usr/bin/env python3
"""Verify pinned archives and every source file, including reused build caches."""
import hashlib
from pathlib import Path
import sys
import tarfile


def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(block)
    return result.hexdigest()


def verify_source(archive_path, expected, source_path):
    archive_path, source_path = Path(archive_path), Path(source_path)
    with archive_path.open("rb") as stream:
        if digest(stream) != expected:
            raise ValueError(f"source archive SHA256 mismatch: {archive_path}")
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        files = {Path(member.name).relative_to(source_path.name): member
                 for member in members if member.isfile()}
        if not source_path.exists():
            archive.extractall(source_path.parent, filter="data")
        for relative, member in files.items():
            actual = source_path / relative
            if actual.is_symlink() or not actual.is_file():
                raise ValueError(f"source cache file missing or changed: {actual}")
            with actual.open("rb") as stream, archive.extractfile(member) as original:
                if digest(stream) != digest(original):
                    raise ValueError(f"source cache differs from verified archive: {actual}")
        # OpenCV creates a download cache here; it does not contain compiled inputs.
        actual_files = {path.relative_to(source_path) for path in source_path.rglob("*")
                        if path.is_file() and ".cache" not in path.relative_to(source_path).parts}
        if actual_files != set(files):
            raise ValueError(f"source cache contains unexpected files: {source_path}; use a fresh cache")


if __name__ == "__main__":
    try:
        verify_source(*sys.argv[1:])
    except (ValueError, OSError, tarfile.TarError) as error:
        raise SystemExit(str(error))
