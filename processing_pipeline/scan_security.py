"""Bounded scan metadata and contained file references at the upload boundary."""
from __future__ import annotations

import json
import math
import os
import shlex
from pathlib import Path

from PIL import Image

MAX_METADATA_BYTES = 8 * 1024 * 1024
MAX_FRAMES = 10000
MAX_IMAGE_PIXELS = 32_000_000
MAX_IMAGE_DIMENSION = 8192
MAX_TOTAL_FRAME_PIXELS = 200_000_000


def contained_path(root, reference, *, require_file=False):
    if (not isinstance(reference, str) or not reference or '\\' in reference or ':' in reference
            or '\x00' in reference or reference.startswith('/')
            or any(part in ('', '.', '..') for part in reference.split('/'))):
        raise ValueError('File paths must remain inside the scan directory')
    scan_root = Path(root).resolve()
    target = (scan_root / reference).resolve()
    if not target.is_relative_to(scan_root) or target == scan_root:
        raise ValueError('File paths must remain inside the scan directory')
    if require_file and not target.is_file():
        raise ValueError('Scan references must name regular files inside the scan directory')
    return str(target)


def load_metadata(path):
    if os.path.getsize(path) > MAX_METADATA_BYTES:
        raise ValueError('Scan metadata exceeds the size limit')
    with open(path, 'rb') as source:
        raw = source.read(MAX_METADATA_BYTES + 1)
    if len(raw) > MAX_METADATA_BYTES:
        raise ValueError('Scan metadata exceeds the size limit')
    return json.loads(raw)


def image_dimensions(path):
    try:
        with Image.open(path) as image:
            width, height = image.size
            if width <= 0 or height <= 0 or width * height > MAX_IMAGE_PIXELS or max(width, height) > MAX_IMAGE_DIMENSION:
                raise ValueError('Scan image exceeds the pixel limit')
            image.verify()
            return width, height
    except (OSError, Image.DecompressionBombError) as error:
        raise ValueError('Scan contains an invalid or oversized image') from error


def validate_intrinsics(value, width, height):
    if not isinstance(value, dict):
        raise ValueError('Camera intrinsics are required')
    for name in ('fx', 'fy', 'cx', 'cy'):
        number = value.get(name)
        if isinstance(number, bool) or not isinstance(number, (float, int)) or not math.isfinite(number):
            raise ValueError('Camera intrinsics must be finite numbers')
    if value['fx'] <= 0 or value['fy'] <= 0 or not 0 <= value['cx'] <= width or not 0 <= value['cy'] <= height:
        raise ValueError('Camera intrinsics are outside the image bounds')


def validate_model_references(scan_root, *, textured):
    """Validate external OBJ/MTL resources before a third-party model reader sees them."""
    obj = contained_path(scan_root, 'model.obj', require_file=True)
    vertices = faces = 0
    with open(obj, encoding='utf-8') as source:
        for line in source:
            parts = line.strip().split()
            if not parts:
                continue
            if parts[0] == 'v':
                if len(parts) < 4 or not all(math.isfinite(float(x)) for x in parts[1:4]):
                    raise ValueError('Model vertices must be finite')
                vertices += 1
            elif parts[0] == 'f':
                if len(parts) < 4:
                    raise ValueError('Model faces must contain at least three vertices')
                faces += 1
            elif parts[0] == 'mtllib':
                for name in shlex.split(line.strip())[1:]:
                    contained_path(scan_root, name, require_file=True)
    if vertices < 3 or faces < 1:
        raise ValueError('Scan must contain a nonempty OBJ mesh')
    if textured:
        contained_path(scan_root, 'model.mtl', require_file=True)
        image_dimensions(contained_path(scan_root, 'texture.jpg', require_file=True))
    # Check all material files, including references in uploaded OBJ declarations.
    for material in Path(scan_root).rglob('*.mtl'):
        material = Path(contained_path(scan_root, str(material.relative_to(Path(scan_root))), require_file=True))
        with material.open(encoding='utf-8') as source:
            for line in source:
                fields = shlex.split(line.strip(), comments=True)
                if fields and (fields[0].startswith('map_') or fields[0] in ('bump', 'disp', 'decal', 'refl')):
                    if len(fields) < 2:
                        raise ValueError('Material texture reference is missing')
                    relative = str(material.parent.relative_to(Path(scan_root)))
                    reference = fields[-1] if relative == '.' else relative + '/' + fields[-1]
                    image_dimensions(contained_path(scan_root, reference, require_file=True))


def validate_scan(scan_root, uv_unwrap=False, *, prepare_uv=False, max_total_frame_pixels=MAX_TOTAL_FRAME_PIXELS):
    """Validate camera data and all actual resources before admitting mobile work."""
    from processing_pipeline.optimized_pipeline import _read_scan_manifest, _source_image_id, arkit_column_major_to_matrix

    validate_model_references(scan_root, textured=not uv_unwrap)
    manifest_path = Path(scan_root) / 'manifest.json'
    intrinsics = None
    if manifest_path.is_file():
        manifest_path = Path(contained_path(scan_root, 'manifest.json', require_file=True))
        normalized = _read_scan_manifest(str(manifest_path))
        source_frames = load_metadata(manifest_path)['frames']
    else:
        poses = load_metadata(contained_path(scan_root, 'poses.json', require_file=True))
        if not isinstance(poses, dict):
            raise ValueError('Camera poses must be an object')
        source_frames = poses.get('frames')
        if not isinstance(source_frames, list) or not source_frames or len(source_frames) > MAX_FRAMES:
            raise ValueError('Scan must contain a bounded nonempty frame list')
        intrinsics_path = Path(scan_root) / 'intrinsics.json'
        if intrinsics_path.is_file():
            intrinsics = load_metadata(contained_path(scan_root, 'intrinsics.json', require_file=True))
        normalized = []
        source_ids = set()
        for ordinal, frame in enumerate(source_frames):
            if not isinstance(frame, dict):
                raise ValueError('Camera frames must be objects')
            normalized.append({'path': frame.get('imageFile'), 'source_image_id': _source_image_id(frame, ordinal, source_ids),
                               'pose': arkit_column_major_to_matrix(frame.get('transform')),
                               'intrinsics': frame.get('intrinsics') or intrinsics})
    if len(normalized) > MAX_FRAMES:
        raise ValueError('Scan exceeds the frame limit')
    total_pixels = 0
    seen = set()
    for frame in normalized:
        path = contained_path(scan_root, frame['path'], require_file=True)
        if path in seen:
            raise ValueError('Camera image references must be unique')
        seen.add(path)
        width, height = image_dimensions(path)
        total_pixels += width * height
        if max_total_frame_pixels is not None and total_pixels > max_total_frame_pixels:
            raise ValueError('Scan images exceed the total pixel limit')
        if 'width' in frame and (frame['width'], frame['height']) != (width, height):
            raise ValueError('Camera metadata does not match image dimensions')
        validate_intrinsics(frame.get('intrinsics'), width, height)
    # UV reads per-frame calibration from poses.json; the first camera is a legacy fallback.
    # Workers request these files only in the independent prepared working directory.
    if uv_unwrap and prepare_uv and manifest_path.is_file():
        calibration = dict(normalized[0]['intrinsics'])
        calibration.update(width=normalized[0]['width'], height=normalized[0]['height'])
        (Path(scan_root) / 'poses.json').write_text(json.dumps({'frames': source_frames}))
        (Path(scan_root) / 'intrinsics.json').write_text(json.dumps(calibration))
    return normalized


def validate_frame_resources(scan_root, *, max_total_frame_pixels=MAX_TOTAL_FRAME_PIXELS):
    """Guard all server entry points before OpenCV, Pillow, or native processing."""
    manifest_path = Path(scan_root) / 'manifest.json'
    if manifest_path.is_file():
        manifest = load_metadata(contained_path(scan_root, 'manifest.json', require_file=True))
        frames = manifest.get('frames') if isinstance(manifest, dict) else None
    else:
        poses = load_metadata(contained_path(scan_root, 'poses.json', require_file=True))
        frames = poses.get('frames') if isinstance(poses, dict) else None
    if not isinstance(frames, list) or not frames or len(frames) > MAX_FRAMES:
        raise ValueError('Scan must contain a bounded nonempty frame list')
    total_pixels = 0
    for frame in frames:
        if not isinstance(frame, dict):
            raise ValueError('Camera frames must be objects')
        width, height = image_dimensions(contained_path(scan_root, frame.get('imageFile'), require_file=True))
        total_pixels += width * height
        if max_total_frame_pixels is not None and total_pixels > max_total_frame_pixels:
            raise ValueError('Scan images exceed the total pixel limit')
    texture = Path(scan_root) / 'texture.jpg'
    if texture.is_file():
        image_dimensions(contained_path(scan_root, 'texture.jpg', require_file=True))
