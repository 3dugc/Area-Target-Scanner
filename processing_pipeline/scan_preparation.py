"""Versioned mobile working scans; uploaded originals are never modified."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import shutil

from PIL import Image

from processing_pipeline.scan_security import (
    MAX_FRAMES, MAX_IMAGE_DIMENSION, MAX_IMAGE_PIXELS, MAX_METADATA_BYTES,
    MAX_TOTAL_FRAME_PIXELS, contained_path, image_dimensions, load_metadata, validate_scan,
)

POLICY = 'mobile-scan-preparation-v1'
POLICY_VERSION = 1
MAX_PROCESSING_FRAMES = 80
MAX_PROCESSING_LONG_EDGE = 1600


def processing_requirements(*, maximum_request_bytes=512 * 1024 * 1024):
    return {'schemaVersion': 1, 'policy': POLICY, 'policyVersion': POLICY_VERSION,
            'profiles': {profile: {'maxFrames': MAX_PROCESSING_FRAMES,
                                  'maximumLongEdge': MAX_PROCESSING_LONG_EDGE,
                                  'maximumTotalPixels': MAX_TOTAL_FRAME_PIXELS}
                         for profile in ('fast', 'quality')},
            'safety': {'maximumRequestBytes': maximum_request_bytes,
                       'maximumExpandedBytes': 500 * 1024 * 1024,
                       'maximumArchiveEntries': 10000, 'maximumSourceFrameCount': MAX_FRAMES,
                       'maximumImagePixels': MAX_IMAGE_PIXELS, 'maximumImageDimension': MAX_IMAGE_DIMENSION,
                       'maximumMetadataBytes': MAX_METADATA_BYTES}}


def selected_frame_indices(count):
    """Uniform full-extent sampling with a portable integer half-up rounding rule."""
    selected = min(count, MAX_PROCESSING_FRAMES)
    if selected == count:
        return list(range(count))
    return [(index * (count - 1) + (selected - 1) // 2) // (selected - 1)
            for index in range(selected)]


def validate_client_preparation(value, *, frame_count, actual_pixels, maximum_long_edge):
    """Bound optional client provenance independently of actual resource checks."""
    if value is None:
        return None
    fields = {'schemaVersion', 'policy', 'policyVersion', 'profile', 'preparedBy', 'originalFrameCount',
              'selectedFrameCount', 'selectedIndices', 'processedPixelCount', 'resizedFrameCount',
              'maximumOutputLongEdge', 'scaleDigest'}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('Client preparation metadata is invalid')
    if (value['schemaVersion'] != 1 or value['policyVersion'] != POLICY_VERSION or value['policy'] != POLICY
            or value['preparedBy'] != 'client' or value['profile'] not in ('fast', 'quality')):
        raise ValueError('Client preparation policy is not supported')
    for name in ('schemaVersion', 'policyVersion', 'originalFrameCount', 'selectedFrameCount',
                 'processedPixelCount', 'resizedFrameCount', 'maximumOutputLongEdge'):
        if isinstance(value[name], bool) or not isinstance(value[name], int) or value[name] < 0:
            raise ValueError('Client preparation counts must be nonnegative integers')
    original = value['originalFrameCount']
    indices = value['selectedIndices']
    if (not 1 <= original <= MAX_FRAMES or value['selectedFrameCount'] != frame_count
            or not 1 <= frame_count <= MAX_PROCESSING_FRAMES or original < frame_count
            or not isinstance(indices, list) or len(indices) != frame_count
            or any(isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < original for index in indices)
            or indices != sorted(set(indices)) or indices[0] != 0 or indices[-1] != original - 1
            or value['processedPixelCount'] != actual_pixels or actual_pixels > MAX_TOTAL_FRAME_PIXELS
            or value['maximumOutputLongEdge'] != maximum_long_edge or maximum_long_edge > MAX_PROCESSING_LONG_EDGE
            or value['resizedFrameCount'] > frame_count
            or not isinstance(value['scaleDigest'], str) or not re.fullmatch('[0-9a-f]{64}', value['scaleDigest'])):
        raise ValueError('Client preparation metadata does not match received resources')
    return dict(value, selectedIndices=list(indices))


@dataclass(frozen=True)
class PreparedScan:
    root: Path
    metadata: dict
    client_preparation: dict | None


def _material_image_paths(root):
    references = set()
    for material in root.rglob('*.mtl'):
        for line in material.read_text(encoding='utf-8').splitlines():
            fields = shlex.split(line.strip(), comments=True)
            if fields and (fields[0].startswith('map_') or fields[0] in ('bump', 'disp', 'decal', 'refl')):
                reference = material.parent.relative_to(root) / fields[-1]
                references.add(str(reference))
    return references


def _output_dimensions(dimensions):
    initial = [(max(1, math.floor(width * min(1, MAX_PROCESSING_LONG_EDGE / max(width, height)))),
                max(1, math.floor(height * min(1, MAX_PROCESSING_LONG_EDGE / max(width, height)))))
               for width, height in dimensions]
    total = sum(width * height for width, height in initial)
    factor = min(1, math.sqrt(MAX_TOTAL_FRAME_PIXELS / total))
    output = [(max(1, math.floor(width * factor)), max(1, math.floor(height * factor)))
              for width, height in initial]
    if sum(width * height for width, height in output) > MAX_TOTAL_FRAME_PIXELS:
        raise ValueError('Prepared scan exceeds the processing pixel budget')
    return output


def prepare_scan(scan_root, destination, *, profile='fast', uv_unwrap=False):
    """Decode one selected frame at a time and write an independent bounded scan."""
    if profile not in ('fast', 'quality'):
        raise ValueError('Processing profile is not supported')
    root, output = Path(scan_root).resolve(), Path(destination).resolve()
    if output.exists() or output.is_relative_to(root) or root.is_relative_to(output):
        raise ValueError('Preparation requires a new directory outside the original scan')
    normalized = validate_scan(root, uv_unwrap, max_total_frame_pixels=None)
    manifest_path = root / 'manifest.json'
    if manifest_path.is_file():
        manifest = load_metadata(manifest_path)
    else:
        manifest = {'schemaVersion': 1, 'coordinateSystem': 'arkit-world',
                    'matrixLayout': 'arkit-column-major', 'units': 'meters',
                    'frames': load_metadata(root / 'poses.json')['frames']}
    source_frames = manifest['frames']
    dimensions = [image_dimensions(contained_path(root, frame['path'], require_file=True)) for frame in normalized]
    client = validate_client_preparation(manifest.get('clientPreparation'), frame_count=len(normalized),
                                       actual_pixels=sum(w * h for w, h in dimensions),
                                       maximum_long_edge=max(max(size) for size in dimensions))
    indices = selected_frame_indices(len(normalized))
    output_sizes = _output_dimensions([dimensions[index] for index in indices])
    camera_paths = {frame['path'] for frame in normalized}
    material_images = _material_image_paths(root)
    output.mkdir(parents=True)
    try:
        # Copy geometry/material resources, never all discarded camera images or shared hardlinks.
        for path in root.rglob('*'):
            if path.is_symlink():
                raise ValueError('Scan resources must not be symbolic links')
            if not path.is_file():
                continue
            relative = str(path.relative_to(root))
            if relative in camera_paths and relative not in material_images:
                continue
            if relative in ('manifest.json', 'poses.json', 'intrinsics.json'):
                continue
            source = contained_path(root, relative, require_file=True)
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        frames, scales = [], []
        frame_directory = 'images'
        while (output / frame_directory).exists() and not (output / frame_directory).is_dir():
            frame_directory += '_prepared'
        resized = 0
        for ordinal, (index, (new_width, new_height)) in enumerate(zip(indices, output_sizes)):
            frame = dict(source_frames[index])
            width, height = dimensions[index]
            resizing = (new_width, new_height) != (width, height)
            suffix = '.jpg' if resizing else (Path(normalized[index]['path']).suffix or '.jpg')
            stem = f'{frame_directory}/prepared_{ordinal:05d}'
            reference = stem + suffix
            collision = 0
            while (output / reference).exists():
                collision += 1
                reference = f'{stem}_{collision}' + suffix
            source = contained_path(root, normalized[index]['path'], require_file=True)
            target = output / reference
            target.parent.mkdir(parents=True, exist_ok=True)
            if not resizing:
                # Header/resource checks already passed; UV/features perform the required decode.
                shutil.copyfile(source, target)
            else:
                resized += 1
                with Image.open(source) as image:
                    with image.convert('RGB') as rgb:
                        with rgb.resize((new_width, new_height), Image.Resampling.LANCZOS) as scaled:
                            scaled.save(target, format='JPEG', quality=90)
            sx, sy = new_width / width, new_height / height
            original_k = normalized[index]['intrinsics']
            frame['imageFile'] = reference
            frame['image'] = {'width': new_width, 'height': new_height}
            frame['intrinsics'] = {'fx': original_k['fx'] * sx, 'fy': original_k['fy'] * sy,
                                   'cx': original_k['cx'] * sx, 'cy': original_k['cy'] * sy}
            frame.setdefault('index', index)
            frame.setdefault('imageOrientation', 'landscapeRight')
            frames.append(frame)
            scales.append({'index': index, 'width': width, 'height': height,
                           'outputWidth': new_width, 'outputHeight': new_height})
        metadata = {'schemaVersion': 1, 'policy': POLICY, 'policyVersion': POLICY_VERSION, 'profile': profile,
                    'preparedBy': 'server', 'originalFrameCount': len(normalized), 'selectedFrameCount': len(frames),
                    'selectedIndices': indices, 'processedPixelCount': sum(w * h for w, h in output_sizes),
                    'resizedFrameCount': resized, 'maximumOutputLongEdge': max(max(size) for size in output_sizes),
                    'scaleDigest': hashlib.sha256(json.dumps(scales, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}
        manifest = dict(manifest, frames=frames, scanPreparation=metadata)
        (output / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True), encoding='utf-8')
        # UV and legacy readers receive the same authoritative per-frame intrinsics.
        (output / 'poses.json').write_text(json.dumps({'frames': frames}), encoding='utf-8')
        calibration = dict(frames[0]['intrinsics'], **frames[0]['image'])
        (output / 'intrinsics.json').write_text(json.dumps(calibration), encoding='utf-8')
        validate_scan(output, uv_unwrap)
        return PreparedScan(output, metadata, client)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
