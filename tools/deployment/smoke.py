#!/usr/bin/env python3
"""Exercise upload -> optimizer -> feature database -> asset download with synthetic data.

Uses only Python's standard library. No camera captures or user scan files are read.
"""
from __future__ import annotations

import argparse
import base64
import io
import hashlib
import secrets
import json
import math
import os
from pathlib import Path
import random
import sqlite3
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
import zlib

WIDTH, HEIGHT = 384, 256
MAX_RESPONSE_BYTES = 50 * 1024 * 1024
# A generated 16x16 neutral JPEG; images used for features are procedural PNGs.
TEXTURE_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/"
    "2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/"
    "wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/"
    "8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/"
    "8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/"
    "8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/"
    "9oADAMBAAIRAxEAPwD1KiiigD//2Q=="
)


def png_image(seed: int, width: int = WIDTH, height: int = HEIGHT) -> bytes:
    """Encode deterministic, corner-rich grayscale pixels as a real PNG."""
    rng = random.Random(seed)
    pixels = bytearray(rng.randrange(256) for _ in range(WIDTH * HEIGHT))
    # Multiple spatial scales keep ORB detections reliable across OpenCV versions.
    for _ in range(180):
        x, y = rng.randrange(24, WIDTH - 40), rng.randrange(24, HEIGHT - 40)
        size, value = rng.randrange(4, 18), rng.choice((0, 255))
        for row in range(y, y + size):
            pixels[row * WIDTH + x:row * WIDTH + x + size] = bytes([value]) * size
    if (width, height) == (WIDTH, HEIGHT):
        rows = [bytes(pixels[y * WIDTH:(y + 1) * WIDTH]) for y in range(HEIGHT)]
    else:
        # Upscale generated texture: genuine high-resolution PNGs, bounded ZIP bytes.
        columns = [x * WIDTH // width for x in range(width)]
        rows = [bytes(pixels[y * WIDTH + x] for x in columns) for y in range(HEIGHT)]
    raw = b"".join(b"\x00" + rows[y * HEIGHT // height] for y in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def model_obj() -> str:
    """A closed textured box whose front fills cameras looking along ARKit -Z."""
    vertices = [(-4, -3, -3), (4, -3, -3), (4, 3, -3), (-4, 3, -3),
                (-4, -3, -3.2), (4, -3, -3.2), (4, 3, -3.2), (-4, 3, -3.2)]
    faces = [(1, 2, 3, 4), (6, 5, 8, 7), (5, 1, 4, 8),
             (2, 6, 7, 3), (4, 3, 7, 8), (5, 6, 2, 1)]
    lines = ["# Synthetic deployment fixture: meters, ARKit -Z view", "mtllib model.mtl", "o synthetic_box"]
    lines.extend(f"v {x} {y} {z}" for x, y, z in vertices)
    lines.extend(("vt 0 0", "vt 1 0", "vt 1 1", "vt 0 1", "usemtl synthetic", "s off"))
    for a, b, c, d in faces:
        lines.extend((f"f {a}/1 {b}/2 {c}/3", f"f {a}/1 {c}/3 {d}/4"))
    return "\n".join(lines) + "\n"


def create_fixture(destination: Path, large_scan: bool = False) -> Path:
    width, height = (1920, 1440) if large_scan else (WIDTH, HEIGHT)
    focal = 1600.0 if large_scan else 320.0
    positions = [(-0.1, 0.0, 0.1)[i % 3] for i in range(100)] if large_scan else (-0.1, 0.0, 0.1)
    frames = []
    for index, tx in enumerate(positions):
        # Flat ARKit column-major camera-to-world: translation at indices 12-14.
        frames.append({
            "index": index, "timestamp": float(index + 1),
            "imageFile": f"images/frame_{index:04d}.png",
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, 0, 0, 1],
            "imageOrientation": "landscapeRight",
            "image": {"width": width, "height": height},
            "intrinsics": {"fx": focal, "fy": focal, "cx": width / 2, "cy": height / 2},
        })
    manifest = {"schemaVersion": 1, "coordinateSystem": "arkit-world",
                "matrixLayout": "arkit-column-major", "units": "meters", "frames": frames}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("model.obj", model_obj())
        archive.writestr("model.mtl", "newmtl synthetic\nKa 0.2 0.2 0.2\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd texture.jpg\n")
        archive.writestr("texture.jpg", TEXTURE_JPEG)
        archive.writestr("poses.json", json.dumps({"frames": frames}))
        archive.writestr("intrinsics.json", json.dumps({"fx": focal, "fy": focal, "cx": width / 2, "cy": height / 2, "width": width, "height": height}))
        archive.writestr("manifest.json", json.dumps(manifest))
        images = [png_image(1024 + i, width, height) for i in range(3)]
        for index, frame in enumerate(frames):
            archive.writestr(frame["imageFile"], images[index % 3])
    return destination


def fetch_response(url: str, deadline: float, data: bytes | None = None,
                   headers: dict | None = None) -> tuple[int, bytes]:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Deployment smoke test exceeded its timeout")
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=min(15, remaining)) as response:
            status, body = response.status, response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read(4096)
    if len(body) > MAX_RESPONSE_BYTES:
        raise RuntimeError("Smoke response exceeds 50 MiB")
    return status, body


def fetch(url: str, deadline: float, data: bytes | None = None,
          headers: dict | None = None) -> bytes:
    status, body = fetch_response(url, deadline, data, headers)
    if status >= 400:
        detail = body.decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {status} at {urllib.parse.urlsplit(url).path}: {detail}")
    return body


def expect_status(url: str, deadline: float, expected: int, headers: dict | None = None) -> None:
    status, _ = fetch_response(url, deadline, headers=headers)
    require(status == expected, f"Expected HTTP {expected} at {urllib.parse.urlsplit(url).path}, got {status}")


def wait_ready(url: str, deadline: float) -> None:
    while time.monotonic() < deadline:
        try:
            fetch(url + "/healthz", deadline)
            return
        except (urllib.error.URLError, OSError, RuntimeError):
            time.sleep(min(1, max(0, deadline - time.monotonic())))
    raise TimeoutError("Pipeline HTTP service did not become ready")


def multipart_fixture(fixture: Path, skip_uv: bool = False) -> tuple[bytes, str]:
    boundary = "area-target-smoke-" + uuid.uuid4().hex
    parts = []
    for name, value in (("profile", "fast"), ("uv_unwrap", "0" if skip_uv else "1")):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="synthetic-scan.zip"\r\nContent-Type: application/zip\r\n\r\n'.encode())
    parts.extend((fixture.read_bytes(), f"\r\n--{boundary}--\r\n".encode()))
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_glb(data: bytes) -> dict:
    require(len(data) >= 28, "GLB is empty or truncated")
    magic, version, length = struct.unpack_from("<4sII", data)
    require(magic == b"glTF" and version == 2 and length == len(data), "Invalid GLB v2 header")
    chunk_length, chunk_type = struct.unpack_from("<II", data, 12)
    require(chunk_type == 0x4e4f534a and chunk_length <= len(data) - 20, "Missing GLB JSON chunk")
    document = json.loads(data[20:20 + chunk_length])
    require(document.get("asset", {}).get("version") == "2.0", "Invalid glTF asset version")
    primitives = [primitive for mesh in document.get("meshes", []) for primitive in mesh.get("primitives", [])]
    require(bool(primitives), "GLB has no mesh primitives")
    accessors = document.get("accessors", [])
    for primitive in primitives:
        position = primitive.get("attributes", {}).get("POSITION")
        require(isinstance(position, int) and 0 <= position < len(accessors), "GLB has no POSITION accessor")
        require(accessors[position].get("count", 0) >= 3, "GLB has no triangle vertices")
    offset = 20 + chunk_length
    require(offset + 8 <= len(data), "GLB has no binary chunk")
    binary_length, binary_type = struct.unpack_from("<II", data, offset)
    require(binary_type == 0x004e4942 and binary_length > 0 and offset + 8 + binary_length == len(data),
            "Invalid or empty GLB binary chunk")
    return document


def verify_bundle(data: bytes, directory: Path) -> dict:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Bundle has duplicate entries")
        require(all(name in names for name in ("manifest.json", "features.db", "optimized.glb")), "Bundle is missing required files")
        require(sum(info.file_size for info in archive.infolist()) <= MAX_RESPONSE_BYTES, "Bundle uncompressed size exceeds 50 MiB")
        manifest = json.loads(archive.read("manifest.json"))
        require(manifest.get("version") == "2.0" and manifest.get("format") == "glb", "Unexpected bundle schema")
        require(manifest.get("meshFile") == "optimized.glb" and manifest.get("featureDbFile") == "features.db", "Manifest references incorrect files")
        verify_glb(archive.read("optimized.glb"))
        database = directory / "features.db"
        database.write_bytes(archive.read("features.db"))
    bounds = manifest.get("bounds", {})
    low, high = bounds.get("min", []), bounds.get("max", [])
    require(len(low) == len(high) == 3 and all(isinstance(x, (int, float)) and math.isfinite(x) for x in low + high), "Invalid manifest bounds")
    require(all(a <= b for a, b in zip(low, high)), "Inverted manifest bounds")
    with sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
        require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "Feature database integrity check failed")
        counts = {table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                  for table in ("keyframes", "features", "vocabulary")}
        require(counts["keyframes"] > 0 and counts["features"] >= 20 and counts["vocabulary"] > 0, "Feature database is empty")
        require(manifest.get("keyframeCount") == counts["keyframes"], "Manifest keyframe count differs from database")
        require(connection.execute("SELECT COUNT(*) FROM features WHERE length(descriptor) <> 32").fetchone()[0] == 0, "Invalid ORB descriptors")
        require(connection.execute("SELECT COUNT(*) FROM features f LEFT JOIN keyframes k ON k.id=f.keyframe_id WHERE k.id IS NULL").fetchone()[0] == 0, "Features reference missing keyframes")
        require(all(count >= 20 for (count,) in connection.execute("SELECT COUNT(*) FROM features GROUP BY keyframe_id")), "Keyframe has fewer than 20 features")
        for (blob,) in connection.execute("SELECT pose FROM keyframes"):
            require(len(blob) == 128, "Invalid pose blob length")
            values = struct.unpack("<16d", blob)
            require(all(math.isfinite(value) for value in values) and values[12:] == (0, 0, 0, 1), "Invalid row-major camera pose")
        for point in connection.execute("SELECT x3d,y3d,z3d FROM features"):
            require(all(math.isfinite(x) and a - 1e-3 <= x <= b + 1e-3 for x, a, b in zip(point, low, high)), "Feature raycast lies outside mesh bounds")
    return {"keyframes": counts["keyframes"], "features": counts["features"], "vocabulary": counts["vocabulary"], "bundle_bytes": len(data), "scan_preparation": manifest.get("scanPreparation")}


def verify_large_preparation(metadata: dict | None) -> None:
    require(isinstance(metadata, dict), "Large scan bundle has no preparation metadata")
    require(metadata.get("policy") == "mobile-scan-preparation-v1" and metadata.get("policyVersion") == 1,
            "Unknown large scan preparation policy")
    require(metadata.get("originalFrameCount") == 100 and metadata.get("selectedFrameCount") == 80,
            "Large scan was not reduced from 100 to 80 frames")
    indices = metadata.get("selectedIndices", [])
    require(len(indices) == 80 and len(set(indices)) == 80 and indices == sorted(indices)
            and indices[0] == 0 and indices[-1] == 99, "Preparation does not cover the original scan")
    require(0 < metadata.get("processedPixelCount", 0) <= 200_000_000
            and 0 < metadata.get("maximumOutputLongEdge", 0) <= 1600,
            "Prepared images exceed processing budgets")


def run_smoke(url: str, timeout: float, skip_uv: bool = False, large_scan: bool = False) -> dict:
    username = os.environ.get("AREA_TARGET_USERNAME", "")
    password = os.environ.get("AREA_TARGET_PASSWORD", "")
    require(bool(username and password), "Set AREA_TARGET_USERNAME and AREA_TARGET_PASSWORD for authenticated smoke checks")
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryDirectory(prefix="area-target-smoke-") as temporary:
        directory = Path(temporary)
        fixture = create_fixture(directory / "synthetic-scan.zip", large_scan=large_scan)
        wait_ready(url, deadline)
        body, content_type = multipart_fixture(fixture, skip_uv=skip_uv)
        job_id = str(uuid.uuid4())
        # Persist identity in this synthetic run before the first network request.
        token = secrets.token_hex(32)
        job_auth = {"Authorization": "Bearer " + token}
        status, _ = fetch_response(url + "/api/upload", deadline, body, {"Content-Type": content_type})
        require(status == 401, f"Unauthenticated legacy upload returned HTTP {status}")
        status, _ = fetch_response(url + "/api/v1/jobs", deadline, body,
                                   {**job_auth, "Idempotency-Key": job_id, "Content-Type": content_type})
        require(status == 401, f"Job token bypassed service login: HTTP {status}")
        login_status, login_body = fetch_response(url + "/api/auth/login", deadline,
                                                  json.dumps({"username": username, "password": password}).encode(),
                                                  {"Content-Type": "application/json"})
        require(login_status == 200, f"Service login returned HTTP {login_status}")
        session = json.loads(login_body)
        require(isinstance(session.get("session_token"), str) and bool(session["session_token"])
                and isinstance(session.get("csrf_token"), str) and bool(session["csrf_token"]),
                "Service login returned an invalid session")
        service_auth = {"X-Area-Target-Session": session["session_token"], "X-CSRF-Token": session["csrf_token"]}
        if large_scan:
            requirements = json.loads(fetch(url + "/api/v1/processing-requirements", deadline, headers=service_auth))
            require(requirements.get("policy") == "mobile-scan-preparation-v1", "Processing requirements are unavailable")
        auth = {**service_auth, **job_auth}
        submit_headers = {**auth, "Idempotency-Key": job_id, "Content-Type": content_type}
        status, response = fetch_response(url + "/api/v1/jobs", deadline, body, submit_headers)
        require(status == 202, f"New protected upload returned HTTP {status}: {response[:4096]!r}")
        uploaded = json.loads(response)
        require(uploaded.get("job_id") == job_id, "Upload identity does not match the client UUID")
        retry_status, retry_response = fetch_response(url + "/api/v1/jobs", deadline, body, submit_headers)
        require(retry_status == 200 and json.loads(retry_response).get("job_id") == job_id,
                "Identical protected retry was not reconciled")
        job_path = urllib.parse.quote(job_id, safe="")
        status_url = f"{url}/api/v1/jobs/{job_path}"
        result_url = status_url + "/result"
        wrong_auth = {**service_auth, "Authorization": "Bearer " + secrets.token_hex(32)}
        expect_status(status_url, deadline, 401)
        expect_status(status_url, deadline, 401, service_auth)
        expect_status(status_url, deadline, 404, wrong_auth)
        expect_status(result_url, deadline, 401)
        expect_status(result_url, deadline, 401, service_auth)
        expect_status(result_url, deadline, 404, wrong_auth)
        expect_status(f"{url}/api/status/{job_path}", deadline, 404, service_auth)
        expect_status(f"{url}/api/download/{job_path}", deadline, 404, service_auth)
        previous = None
        while True:
            job = json.loads(fetch(status_url, deadline, headers=auth))
            marker = (job.get("status"), job.get("stage"))
            if marker != previous:
                print(f"Smoke job {job_id}: {marker[0]} / {marker[1]}", flush=True)
                previous = marker
            if job.get("status") == "completed":
                break
            if job.get("status") == "failed":
                raise RuntimeError(f"Pipeline job failed: {job.get('error')}")
            require(job.get("status") in ("queued", "extracting", "processing"), "Unexpected pipeline job status")
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        metadata = job.get("result")
        require(isinstance(metadata, dict) and metadata.get("format") == "area-target-bundle"
                and metadata.get("url") == f"/api/v1/jobs/{job_path}/result", "Invalid protected result metadata")
        bundle = fetch(result_url, deadline, headers=auth)
        require(len(bundle) == metadata.get("size_bytes"), "Downloaded ZIP byte count does not match result metadata")
        require(hashlib.sha256(bundle).hexdigest() == metadata.get("sha256"), "Downloaded ZIP SHA256 does not match result metadata")
        expect_status(f"{url}/api/download/{job_path}", deadline, 404, service_auth)
        verified = verify_bundle(bundle, directory)
        if large_scan:
            verify_large_preparation(verified.get("scan_preparation"))
            require(verified["keyframes"] <= 80 and verified["features"] <= 80_000
                    and verified["vocabulary"] <= 500, "Large fast scan exceeds iOS feature database budgets")
        return {"job_id": job_id, "size_bytes": len(bundle), "sha256": metadata["sha256"],
                "protected_api": True, "service_login": True, **verified}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--url", help="Pipeline base URL; e.g. http://127.0.0.1:8080")
    action.add_argument("--fixture-only", type=Path, metavar="ZIP", help="Write a synthetic scan ZIP and skip HTTP operations")
    parser.add_argument("--large-scan", action="store_true", help="Exercise 100 original 1920x1440 frames and bounded server preparation")
    parser.add_argument("--skip-uv", action="store_true", help="Skip the default native xatlas UV unwrap stage")
    parser.add_argument("--timeout", type=float, default=180, help="Overall service startup and processing timeout in seconds (default: 180)")
    args = parser.parse_args()
    try:
        if args.fixture_only:
            path = create_fixture(args.fixture_only.resolve(), large_scan=args.large_scan)
            print(json.dumps({"fixture": str(path), "bytes": path.stat().st_size, "frames": 100 if args.large_scan else 3}))
            return 0
        parsed = urllib.parse.urlsplit(args.url)
        require(parsed.scheme in ("http", "https") and bool(parsed.netloc) and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
                "--url must be an HTTP(S) base URL without credentials, query, or fragment")
        require(math.isfinite(args.timeout) and args.timeout > 0, "--timeout must be a positive finite number")
        result = run_smoke(args.url.rstrip("/"), args.timeout, skip_uv=args.skip_uv, large_scan=args.large_scan)
        print("Synthetic pipeline smoke passed: " + json.dumps(result, sort_keys=True), flush=True)
        return 0
    except Exception as error:
        print(f"Synthetic pipeline smoke failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
