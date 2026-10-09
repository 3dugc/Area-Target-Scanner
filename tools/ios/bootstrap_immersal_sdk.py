#!/usr/bin/env python3
"""Restore the pinned proprietary iPhoneOS SDK locally; never stage or build it.

Only Python's standard library is required. An existing matching artifact stays
offline and untouched. Different existing bytes are never overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DESTINATION = ROOT / "ios_scanner/AreaTargetScanner/ThirdParty/Immersal/libPosePlugin.a"
PINNED_COMMIT = "6fd5c0bf42c86c35c97630c84df4438388e7f7c8"
EXPECTED_SHA256 = "45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f"
ARTIFACT_URL = ("https://github.com/immersal/imdk-unity/raw/" + PINNED_COMMIT
                + "/Runtime/Plugins/iOS/libPosePlugin.a")
MAX_BYTES = 64 * 1024 * 1024
OFFICIAL_HOSTS = {"github.com", "raw.githubusercontent.com", "media.githubusercontent.com"}


class OfficialArtifactRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        parsed = urllib.parse.urlsplit(new_url)
        if (parsed.scheme != "https" or parsed.hostname not in OFFICIAL_HOSTS
                or parsed.username or parsed.password or parsed.port not in (None, 443)):
            raise ValueError("refusing artifact redirect outside official HTTPS hosts")
        return super().redirect_request(request, fp, code, message, headers, new_url)


def open_official_artifact():
    opener = urllib.request.build_opener(OfficialArtifactRedirectHandler())
    request = urllib.request.Request(ARTIFACT_URL, headers={"User-Agent": "AreaTargetSDKRestore/1"})
    return opener.open(request, timeout=60)


def verified_existing(destination):
    """Return the verified byte count, or None when the artifact is absent."""
    try:
        info = destination.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("SDK destination must be a regular file, not a symlink or directory")
    fd = os.open(destination, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("SDK destination must be a regular file")
        digest = hashlib.sha256()
        size = 0
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(block)
            if size > MAX_BYTES:
                raise ValueError("existing SDK size exceeds the allowed maximum")
            digest.update(block)
    if digest.hexdigest() != EXPECTED_SHA256:
        raise ValueError("existing SDK SHA256 mismatch; refusing to overwrite: " + str(destination))
    return size


def bootstrap(destination=DEFAULT_DESTINATION, *, open_artifact=None):
    destination = Path(destination).expanduser().absolute()

    def receipt(status, size):
        return {"status": status, "path": str(destination), "bytes": size,
                "sha256": EXPECTED_SHA256, "upstreamCommit": PINNED_COMMIT,
                "artifactURL": ARTIFACT_URL}

    existing = verified_existing(destination)
    if existing is not None:
        return receipt("reused", existing)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fetch = open_artifact or open_official_artifact
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=destination.parent,
                                         prefix="." + destination.name + ".download-",
                                         delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.sha256()
            size = 0
            with fetch() as response:
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    size += len(block)
                    if size > MAX_BYTES:
                        raise ValueError("download size is too large")
                    digest.update(block)
                    output.write(block)
            if digest.hexdigest() != EXPECTED_SHA256:
                raise ValueError("downloaded SDK SHA256 mismatch; no artifact was installed")
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o644)
        try:
            # Same-directory hard linking publishes atomically and cannot replace
            # a file installed by another process during the download.
            os.link(temporary, destination)
        except FileExistsError:
            return receipt("reused", verified_existing(destination))
        return receipt("downloaded", size)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION,
                        help="local artifact path; defaults to the Xcode project's SDK path")
    arguments = parser.parse_args()
    try:
        result = bootstrap(arguments.destination)
    except (OSError, ValueError) as error:
        parser.exit(1, "FAIL Immersal SDK restore: " + str(error) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
