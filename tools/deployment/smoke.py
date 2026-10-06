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
V2_POLICY = "mobile-scan-preparation-v2"
V2_SIZES = ((1920, 1440), (1600, 1200), (384, 256), (384, 256))
CRITICAL_CAPABILITY = {
    "version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
    "maximumProtectedFrames": 8, "maximumProtectedLongEdge": 1920,
    "sharpnessThreshold": 16, "contrastThreshold": 20,
}
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


def _digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _v2_scale_digest(count: int) -> str:
    return _digest([{"index": i, "width": w, "height": h, "outputWidth": w, "outputHeight": h}
                    for i, (w, h) in enumerate(V2_SIZES[:count])])


def _v2_client_preparation() -> dict:
    indices = list(range(4))
    return {"schemaVersion": 1, "policy": V2_POLICY, "policyVersion": 2, "profile": "fast",
            "preparedBy": "client", "originalFrameCount": 4, "receivedFrameCount": 4,
            "selectedFrameCount": 4, "selectedIndices": indices,
            "processedPixelCount": sum(w * h for w, h in V2_SIZES), "resizedFrameCount": 0,
            "maximumOutputLongEdge": 1920, "scaleDigest": _v2_scale_digest(4),
            "capacityTier": 100, "selectionVersion": "upload-all-v2",
            "selectionDigest": _digest({"capacityTier": 100, "policy": V2_POLICY,
                "selectedIndices": indices, "selectionVersion": "upload-all-v2"}),
            "criticalFrameProtection": {"version": CRITICAL_CAPABILITY["version"],
                "riskVersion": CRITICAL_CAPABILITY["riskVersion"],
                "protectedIndices": [0], "candidateFrameCount": 1}}


def _create_v2_fixture(destination: Path) -> Path:
    # Only frames 2/3 share pose and encoded pixels; different views are >8cm apart.
    frames, images = [], []
    for index, ((width, height), tx) in enumerate(zip(V2_SIZES, (-.25, 0, .25, .25))):
        focal = width * 320.0 / WIDTH
        frames.append({"index": index, "timestamp": float(index + 1),
            "imageFile": f"images/frame_{index:04d}.png",
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, 0, 0, 1],
            "imageOrientation": "landscapeRight", "image": {"width": width, "height": height},
            "intrinsics": {"fx": focal, "fy": focal, "cx": width / 2, "cy": height / 2}})
        images.append(png_image(1024 + index, width, height) if index < 3 else images[2])
    manifest = {"schemaVersion": 1, "coordinateSystem": "arkit-world",
                "matrixLayout": "arkit-column-major", "units": "meters", "frames": frames,
                "clientPreparation": _v2_client_preparation()}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("model.obj", model_obj())
        archive.writestr("model.mtl", "newmtl synthetic\nKa 0.2 0.2 0.2\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd texture.jpg\n")
        archive.writestr("texture.jpg", TEXTURE_JPEG)
        archive.writestr("poses.json", json.dumps({"frames": frames}))
        archive.writestr("intrinsics.json", json.dumps({**frames[0]["intrinsics"], **frames[0]["image"]}))
        archive.writestr("manifest.json", json.dumps(manifest))
        for frame, pixels in zip(frames, images):
            archive.writestr(frame["imageFile"], pixels)
    return destination


def create_fixture(destination: Path, large_scan: bool = False, preparation_v2: bool = False) -> Path:
    require(not (large_scan and preparation_v2), "Choose either --large-scan or --preparation-v2")
    if preparation_v2:
        return _create_v2_fixture(destination)
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
        akaze_count = (connection.execute("SELECT COUNT(*) FROM akaze_features").fetchone()[0]
                       if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='akaze_features'").fetchone()
                       else 0)
        keyframe_ids = [row[0] for row in connection.execute("SELECT id FROM keyframes ORDER BY id")]
        frame_counts = {str(frame): count for frame, count in
                        connection.execute("SELECT keyframe_id,COUNT(*) FROM features GROUP BY keyframe_id")}
        pixel_bounds = {str(frame): {"max_x": x, "max_y": y} for frame, x, y in
                        connection.execute("SELECT keyframe_id,MAX(x),MAX(y) FROM features GROUP BY keyframe_id")}
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
    producer = manifest.get("producer")
    return {"keyframes": counts["keyframes"], "features": counts["features"], "vocabulary": counts["vocabulary"],
            "akaze_features": akaze_count, "keyframe_ids": keyframe_ids,
            "keyframe_feature_counts": frame_counts, "keyframe_pixel_bounds": pixel_bounds,
            "bundle_bytes": len(data), "scan_preparation": manifest.get("scanPreparation"),
            "client_preparation": manifest.get("clientPreparation"),
            "feature_selection": producer.get("keyframeSelection") if isinstance(producer, dict) else None}


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


def verify_v2_requirements(requirements: dict) -> None:
    require(requirements.get("schemaVersion") == 1 and requirements.get("policy") == V2_POLICY
            and requirements.get("policyVersion") == 2 and requirements.get("capacityTier") == 100,
            "V2 processing requirements are unavailable")
    require(requirements.get("criticalFrameProtection") == CRITICAL_CAPABILITY,
            "Unsupported critical protection capability")
    require(requirements.get("profiles", {}).get("fast") == {
        "maxFrames": 100, "maximumLongEdge": 1600, "minimumLongEdge": 1024,
        "maximumTotalPixels": 200_000_000}, "Unexpected v2 fast preparation budgets")


def verify_v2_preparation(verified: dict) -> None:
    preparation = verified.get("scan_preparation")
    require(isinstance(preparation, dict), "V2 scan bundle has no preparation metadata")
    expected = {"schemaVersion": 1, "policy": V2_POLICY, "policyVersion": 2, "profile": "fast",
        "preparedBy": "server", "originalFrameCount": 4, "receivedFrameCount": 4,
        "selectedFrameCount": 3, "selectedIndices": [0, 1, 2], "duplicateFrameCount": 1,
        "duplicateGroups": [{"representativeIndex": 2, "duplicateIndices": [3]}],
        "selectionVersion": "pose-visual-dedup-v1", "capacityTier": 100,
        "maximumTotalPixels": 200_000_000, "processedPixelCount": sum(w * h for w, h in V2_SIZES[:3]),
        "maximumOutputLongEdge": 1920, "resizedFrameCount": 0, "scaleDigest": _v2_scale_digest(3),
        "criticalFrameProtection": {"version": CRITICAL_CAPABILITY["version"],
            "riskVersion": CRITICAL_CAPABILITY["riskVersion"], "candidateFrameCount": 1,
            "requestedProtectedIndices": [0], "protectedIndices": [0], "deduplicatedProtectedIndices": []}}
    expected["selectionDigest"] = hashlib.sha256(json.dumps({
        "policy": V2_POLICY, "capacityTier": 100,
        "selectionVersion": expected["selectionVersion"],
        "selectedIndices": expected["selectedIndices"],
        "duplicateGroups": expected["duplicateGroups"],
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    for field, value in expected.items():
        require(preparation.get(field) == value, f"V2 preparation did not exercise expected {field}")
    require(verified.get("client_preparation") == _v2_client_preparation(),
            "V2 client preparation provenance was not preserved")
    require(verified.get("keyframes") == 3 and verified.get("keyframe_ids") == [0, 1, 2],
            "V2 database did not retain all three distinct views")
    require(60 <= verified.get("features", 0) <= 200_000 and verified.get("akaze_features") == 0
            and 0 < verified.get("vocabulary", 0) <= 500, "V2 fast database exceeds feature budgets")
    counts = verified.get("keyframe_feature_counts", {})
    require(set(counts) == {"0", "1", "2"} and all(count >= 20 for count in counts.values()),
            "V2 retained view has no usable 3D features")
    selection = verified.get("feature_selection")
    require(isinstance(selection, dict), "V2 database has no feature budget diagnostics")
    feature_expected = {"version": "prepared-coverage-v2", "featureBudgetVersion": "balanced-mobile-features-v1",
        "featureBudgetProfile": "fast", "inputFrameCount": 3, "selectedFrameCount": 3,
        "retainedIndices": [0, 1, 2], "orbFeatureCount": verified["features"], "akazeFeatureCount": 0,
        "vocabularySize": verified["vocabulary"], "retainedKeyframeCount": 3,
        "insufficientFeatureFrameCount": 0, "insufficientFeatureFrameIndices": [],
        "unreadableFrameCount": 0, "unreadableFrameIndices": []}
    for field, value in feature_expected.items():
        require(selection.get(field) == value, f"V2 feature diagnostics differ at {field}")
    bounds = verified.get("keyframe_pixel_bounds", {})
    require(set(bounds) == {"0", "1", "2"}, "V2 database has incomplete pixel coordinates")
    for index, (width, height) in enumerate(V2_SIZES[:3]):
        coordinate = bounds[str(index)]
        require(all(isinstance(coordinate.get(axis), (int, float)) and math.isfinite(coordinate[axis])
                    and 0 <= coordinate[axis] < edge
                    for axis, edge in (("max_x", width), ("max_y", height))),
                "V2 database pixel coordinates exceed the prepared raster")
    require(bounds["0"]["max_x"] > 1600 and bounds["0"]["max_y"] > 1200,
            "Protected view has no actual high-resolution feature coordinates")


def run_smoke(url: str, timeout: float, skip_uv: bool = False, large_scan: bool = False,
              preparation_v2: bool = False) -> dict:
    username = os.environ.get("AREA_TARGET_USERNAME", "")
    password = os.environ.get("AREA_TARGET_PASSWORD", "")
    require(bool(username and password), "Set AREA_TARGET_USERNAME and AREA_TARGET_PASSWORD for authenticated smoke checks")
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryDirectory(prefix="area-target-smoke-") as temporary:
        directory = Path(temporary)
        fixture = create_fixture(directory / "synthetic-scan.zip", large_scan=large_scan,
                                 preparation_v2=preparation_v2)
        wait_ready(url, deadline)
        body, content_type = multipart_fixture(fixture, skip_uv=skip_uv)
        job_id = str(uuid.uuid4())
        # Persist identity in this synthetic run before the first network request.
        token = secrets.token_hex(32)
        job_auth = {"Authorization": "Bearer " + token}
        # Authentication rejects before reading uploads; keep probes tiny so early close cannot break a large send.
        status, _ = fetch_response(url + "/api/upload", deadline, b"", {"Content-Type": content_type})
        require(status == 401, f"Unauthenticated legacy upload returned HTTP {status}")
        status, _ = fetch_response(url + "/api/v1/jobs", deadline, b"",
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
        if preparation_v2:
            requirements = json.loads(fetch(url + "/api/v1/processing-requirements?policy=" + V2_POLICY,
                                           deadline, headers=service_auth))
            verify_v2_requirements(requirements)
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
        if preparation_v2:
            verify_v2_preparation(verified)
            verified["preparation_v2"] = True
        return {"job_id": job_id, "size_bytes": len(bundle), "sha256": metadata["sha256"],
                "protected_api": True, "service_login": True, **verified}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--url", help="Pipeline base URL; e.g. http://127.0.0.1:8080")
    action.add_argument("--fixture-only", type=Path, metavar="ZIP", help="Write a synthetic scan ZIP and skip HTTP operations")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--large-scan", action="store_true", help="Exercise 100 original 1920x1440 frames and bounded server preparation")
    mode.add_argument("--preparation-v2", action="store_true", help="Exercise v2 deduplication, mixed resolutions and critical frame protection")
    parser.add_argument("--skip-uv", action="store_true", help="Skip the default native xatlas UV unwrap stage")
    parser.add_argument("--timeout", type=float, default=180, help="Overall service startup and processing timeout in seconds (default: 180)")
    args = parser.parse_args()
    try:
        if args.fixture_only:
            path = create_fixture(args.fixture_only.resolve(), large_scan=args.large_scan,
                                  preparation_v2=args.preparation_v2)
            print(json.dumps({"fixture": str(path), "bytes": path.stat().st_size,
                              "frames": 4 if args.preparation_v2 else (100 if args.large_scan else 3)}))
            return 0
        parsed = urllib.parse.urlsplit(args.url)
        require(parsed.scheme in ("http", "https") and bool(parsed.netloc) and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
                "--url must be an HTTP(S) base URL without credentials, query, or fragment")
        require(math.isfinite(args.timeout) and args.timeout > 0, "--timeout must be a positive finite number")
        result = run_smoke(args.url.rstrip("/"), args.timeout, skip_uv=args.skip_uv,
                           large_scan=args.large_scan, preparation_v2=args.preparation_v2)
        print("Synthetic pipeline smoke passed: " + json.dumps(result, sort_keys=True), flush=True)
        return 0
    except Exception as error:
        print(f"Synthetic pipeline smoke failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
