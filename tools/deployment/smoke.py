#!/usr/bin/env python3
"""Exercise upload -> optimizer -> feature database -> asset download with synthetic data.

Uses only Python's standard library. No camera captures or user scan files are read.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
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


def png_image(seed: int) -> bytes:
    """Encode deterministic, corner-rich grayscale pixels as a real PNG."""
    rng = random.Random(seed)
    pixels = bytearray(rng.randrange(256) for _ in range(WIDTH * HEIGHT))
    # Multiple spatial scales keep ORB detections reliable across OpenCV versions.
    for _ in range(180):
        x, y = rng.randrange(24, WIDTH - 40), rng.randrange(24, HEIGHT - 40)
        size, value = rng.randrange(4, 18), rng.choice((0, 255))
        for row in range(y, y + size):
            pixels[row * WIDTH + x:row * WIDTH + x + size] = bytes([value]) * size
    raw = b"".join(b"\x00" + pixels[y * WIDTH:(y + 1) * WIDTH] for y in range(HEIGHT))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 0, 0, 0, 0))
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


def create_fixture(destination: Path) -> Path:
    frames = []
    for index, tx in enumerate((-0.1, 0.0, 0.1)):
        # Flat ARKit column-major camera-to-world: translation at indices 12-14.
        frames.append({
            "index": index, "timestamp": float(index + 1),
            "imageFile": f"images/frame_{index:04d}.png",
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, 0, 0, 1],
            "imageOrientation": "landscapeRight",
            "image": {"width": WIDTH, "height": HEIGHT},
            "intrinsics": {"fx": 320.0, "fy": 320.0, "cx": WIDTH / 2, "cy": HEIGHT / 2},
        })
    manifest = {"schemaVersion": 1, "coordinateSystem": "arkit-world",
                "matrixLayout": "arkit-column-major", "units": "meters", "frames": frames}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("model.obj", model_obj())
        archive.writestr("model.mtl", "newmtl synthetic\nKa 0.2 0.2 0.2\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd texture.jpg\n")
        archive.writestr("texture.jpg", TEXTURE_JPEG)
        archive.writestr("poses.json", json.dumps({"frames": frames}))
        archive.writestr("intrinsics.json", json.dumps({"fx": 320.0, "fy": 320.0, "cx": WIDTH / 2, "cy": HEIGHT / 2, "width": WIDTH, "height": HEIGHT}))
        archive.writestr("manifest.json", json.dumps(manifest))
        for index, frame in enumerate(frames):
            archive.writestr(frame["imageFile"], png_image(1024 + index))
    return destination


def fetch(url: str, deadline: float, data: bytes | None = None,
          headers: dict | None = None) -> bytes:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Deployment smoke test exceeded its timeout")
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=min(15, remaining)) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        detail = error.read(4096).decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code} at {urllib.parse.urlsplit(url).path}: {detail}") from error
    if len(body) > MAX_RESPONSE_BYTES:
        raise RuntimeError("Smoke response exceeds 50 MiB")
    return body


def wait_ready(url: str, deadline: float) -> None:
    while time.monotonic() < deadline:
        try:
            fetch(url + "/", deadline)
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
    return {"keyframes": counts["keyframes"], "features": counts["features"], "vocabulary": counts["vocabulary"], "bundle_bytes": len(data)}


def run_smoke(url: str, timeout: float, skip_uv: bool = False) -> dict:
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryDirectory(prefix="area-target-smoke-") as temporary:
        directory = Path(temporary)
        fixture = create_fixture(directory / "synthetic-scan.zip")
        wait_ready(url, deadline)
        body, content_type = multipart_fixture(fixture, skip_uv=skip_uv)
        uploaded = json.loads(fetch(url + "/api/upload", deadline, body, {"Content-Type": content_type}))
        job_id = uploaded.get("job_id")
        require(isinstance(job_id, str) and bool(job_id), "Upload did not return a job_id")
        job_path = urllib.parse.quote(job_id, safe="")
        previous = None
        while True:
            job = json.loads(fetch(f"{url}/api/status/{job_path}", deadline))
            marker = (job.get("status"), job.get("step"))
            if marker != previous:
                print(f"Smoke job {job_id}: {marker[0]} / {marker[1]}", flush=True)
                previous = marker
            if job.get("status") == "completed":
                break
            if job.get("status") == "failed":
                raise RuntimeError(f"Pipeline job failed: {job.get('error')}")
            require(job.get("status") in ("queued", "extracting", "processing"), "Unexpected pipeline job status")
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        bundle = fetch(f"{url}/api/download/{job_path}", deadline)
        return {"job_id": job_id, **verify_bundle(bundle, directory)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--url", help="Pipeline base URL; e.g. http://127.0.0.1:8080")
    action.add_argument("--fixture-only", type=Path, metavar="ZIP", help="Write a synthetic scan ZIP and skip HTTP operations")
    parser.add_argument("--skip-uv", action="store_true", help="Skip the default native xatlas UV unwrap stage")
    parser.add_argument("--timeout", type=float, default=180, help="Overall service startup and processing timeout in seconds (default: 180)")
    args = parser.parse_args()
    try:
        if args.fixture_only:
            path = create_fixture(args.fixture_only.resolve())
            print(json.dumps({"fixture": str(path), "bytes": path.stat().st_size, "frames": 3}))
            return 0
        parsed = urllib.parse.urlsplit(args.url)
        require(parsed.scheme in ("http", "https") and bool(parsed.netloc) and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
                "--url must be an HTTP(S) base URL without credentials, query, or fragment")
        require(math.isfinite(args.timeout) and args.timeout > 0, "--timeout must be a positive finite number")
        result = run_smoke(args.url.rstrip("/"), args.timeout, skip_uv=args.skip_uv)
        print("Synthetic pipeline smoke passed: " + json.dumps(result, sort_keys=True), flush=True)
        return 0
    except Exception as error:
        print(f"Synthetic pipeline smoke failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
