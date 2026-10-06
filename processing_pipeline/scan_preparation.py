"""Versioned mobile working scans; uploaded originals are never modified."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
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
POLICY_V2 = 'mobile-scan-preparation-v2'
MAX_PROCESSING_FRAMES = 80
MAX_PROCESSING_LONG_EDGE = 1600
# Quality inspects every original view before the 80-frame derivative budget.
# Bound cumulative decode work as well as peak image size and archive bytes.
MAX_SOURCE_QUALITY_PIXELS = 10 * MAX_TOTAL_FRAME_PIXELS


class PreparationError(ValueError):
    def __init__(self, code, message, **details):
        self.code, self.details = code, details
        super().__init__(f'{code}: {message}')


@dataclass(frozen=True)
class WorkingImagePolicy:
    max_frames: int
    maximum_long_edge: int
    minimum_long_edge: int
    maximum_total_pixels: int


def enabled_capacity():
    value = os.environ.get('AREA_TARGET_PREPARATION_TIER', '100')
    if value not in ('100', '500'):
        raise ValueError('AREA_TARGET_PREPARATION_TIER must be 100 or 500')
    return int(value)


def working_policy(capacity=None):
    allowed = enabled_capacity()
    tier = allowed if capacity is None else capacity
    if isinstance(tier, bool) or not isinstance(tier, int) or tier not in (100, 500) or tier > allowed:
        raise PreparationError('coverage_budget_exceeded', 'The requested capacity is not enabled on this service.')
    return WorkingImagePolicy(tier, 1600, 1024, 200_000_000 if tier == 100 else 600_000_000)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def upload_selection_digest(capacity, indices):
    return _digest({'capacityTier': capacity, 'policy': POLICY_V2, 'selectedIndices': indices,
                    'selectionVersion': 'upload-all-v2'})


def processing_requirements(*, maximum_request_bytes=512 * 1024 * 1024, policy=POLICY):
    if policy not in (POLICY, POLICY_V2):
        raise PreparationError('unsupported_preparation_policy', 'The preparation policy is not supported.')
    result = {'schemaVersion': 1, 'policy': POLICY, 'policyVersion': POLICY_VERSION,
            'profiles': {profile: {'maxFrames': MAX_PROCESSING_FRAMES,
                                  'maximumLongEdge': MAX_PROCESSING_LONG_EDGE,
                                  'maximumTotalPixels': MAX_TOTAL_FRAME_PIXELS}
                         for profile in ('fast', 'quality')},
            'safety': {'maximumRequestBytes': maximum_request_bytes,
                       'maximumExpandedBytes': 500 * 1024 * 1024,
                       'maximumArchiveEntries': 10000, 'maximumSourceFrameCount': MAX_FRAMES,
                       'maximumImagePixels': MAX_IMAGE_PIXELS, 'maximumImageDimension': MAX_IMAGE_DIMENSION,
                       'maximumMetadataBytes': MAX_METADATA_BYTES}}
    if policy == POLICY_V2:
        from processing_pipeline.critical_frame_protection import capability
        settings = working_policy()
        result.update(policy=POLICY_V2, policyVersion=2, capacityTier=settings.max_frames)
        result['criticalFrameProtection'] = capability()
        result['profiles'] = {profile: {'maxFrames': settings.max_frames,
            'maximumLongEdge': settings.maximum_long_edge, 'minimumLongEdge': settings.minimum_long_edge,
            'maximumTotalPixels': settings.maximum_total_pixels} for profile in ('fast', 'quality')}
        result['keyframeSelection'] = {'version': 'pose-visual-dedup-v1',
                                       'maximumSourceQualityPixels': MAX_SOURCE_QUALITY_PIXELS}
    return result


def selected_frame_indices(count):
    """Uniform full-extent sampling with a portable integer half-up rounding rule."""
    selected = min(count, MAX_PROCESSING_FRAMES)
    if selected == count:
        return list(range(count))
    return [(index * (count - 1) + (selected - 1) // 2) // (selected - 1)
            for index in range(selected)]


def validate_client_preparation(value, *, frame_count, actual_pixels, maximum_long_edge, dimensions=None):
    """Bound optional client provenance independently of actual resource checks."""
    if value is None:
        return None
    fields = {'schemaVersion', 'policy', 'policyVersion', 'profile', 'preparedBy', 'originalFrameCount',
              'selectedFrameCount', 'selectedIndices', 'processedPixelCount', 'resizedFrameCount',
              'maximumOutputLongEdge', 'scaleDigest'}
    is_v2 = isinstance(value, dict) and value.get('policy') == POLICY_V2
    if is_v2:
        fields |= {'receivedFrameCount', 'capacityTier', 'selectionVersion', 'selectionDigest'}
        if 'criticalFrameProtection' in value:
            fields.add('criticalFrameProtection')
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('Client preparation metadata is invalid')
    if (value['schemaVersion'] != 1 or value['policyVersion'] != (2 if is_v2 else POLICY_VERSION)
            or value['policy'] != (POLICY_V2 if is_v2 else POLICY)
            or value['preparedBy'] != 'client' or value['profile'] not in ('fast', 'quality')):
        raise ValueError('Client preparation policy is not supported')
    for name in ('schemaVersion', 'policyVersion', 'originalFrameCount', 'selectedFrameCount',
                 'processedPixelCount', 'resizedFrameCount', 'maximumOutputLongEdge'):
        if isinstance(value[name], bool) or not isinstance(value[name], int) or value[name] < 0:
            raise ValueError('Client preparation counts must be nonnegative integers')
    original = value['originalFrameCount']
    indices = value['selectedIndices']
    protection = None
    allowed_long_edge = MAX_PROCESSING_LONG_EDGE
    if is_v2 and 'criticalFrameProtection' in value:
        from processing_pipeline.critical_frame_protection import MAXIMUM_PROTECTED_LONG_EDGE, validate_request
        protection = validate_request(value['criticalFrameProtection'], frame_count)
        allowed_long_edge = MAXIMUM_PROTECTED_LONG_EDGE
        if not isinstance(dimensions, (list, tuple)) or len(dimensions) != frame_count:
            raise ValueError('Critical frame protection requires actual per-frame dimensions')
        protected = set(protection['protectedIndices'])
        for ordinal, size in enumerate(dimensions):
            if (not isinstance(size, (list, tuple)) or len(size) != 2
                    or any(isinstance(n, bool) or not isinstance(n, int) or n < 1 for n in size)
                    or max(size) > (allowed_long_edge if ordinal in protected else MAX_PROCESSING_LONG_EDGE)):
                raise ValueError('Critical frame protection does not match actual per-frame dimensions')
        if (sum(w * h for w, h in dimensions) != actual_pixels
                or max(max(size) for size in dimensions) != maximum_long_edge):
            raise ValueError('Critical frame protection dimensions do not match received resources')
    if (not 1 <= original <= MAX_FRAMES or value['selectedFrameCount'] != frame_count
            or not 1 <= frame_count <= (MAX_FRAMES if is_v2 else MAX_PROCESSING_FRAMES) or original < frame_count
            or not isinstance(indices, list) or len(indices) != frame_count
            or any(isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < original for index in indices)
            or indices != sorted(set(indices)) or indices[0] != 0 or indices[-1] != original - 1
            or value['processedPixelCount'] != actual_pixels
            or actual_pixels > (MAX_SOURCE_QUALITY_PIXELS if is_v2 else MAX_TOTAL_FRAME_PIXELS)
            or value['maximumOutputLongEdge'] != maximum_long_edge or maximum_long_edge > allowed_long_edge
            or value['resizedFrameCount'] > frame_count
            or not isinstance(value['scaleDigest'], str) or not re.fullmatch('[0-9a-f]{64}', value['scaleDigest'])):
        raise ValueError('Client preparation metadata does not match received resources')
    if is_v2:
        tier = value['capacityTier']
        working_policy(tier)
        if (isinstance(value['receivedFrameCount'], bool) or not isinstance(value['receivedFrameCount'], int)
                or value['receivedFrameCount'] != frame_count or original != frame_count
                or indices != list(range(frame_count)) or value['selectionVersion'] != 'upload-all-v2'
                or value['selectionDigest'] != upload_selection_digest(tier, indices)):
            raise ValueError('Client preparation selection does not match received resources')
    result = dict(value, selectedIndices=list(indices))
    if protection is not None:
        result['criticalFrameProtection'] = protection
    return result


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


def working_image_sizes(dimensions, policy, *, protected_indices=()):
    """Share a pixel budget without dropping views or crossing the resolution floor."""
    if len(dimensions) > policy.max_frames:
        raise PreparationError('coverage_budget_exceeded', 'Distinct views exceed the enabled frame capacity.',
                               selectedFrameCount=len(dimensions), maximumFrames=policy.max_frames)
    if not dimensions or any(min(size) < 1 for size in dimensions):
        raise ValueError('Working image dimensions must be positive')
    from processing_pipeline.critical_frame_protection import MAXIMUM_PROTECTED_LONG_EDGE, MAXIMUM_PROTECTED_FRAMES
    if (not isinstance(protected_indices, (list, tuple)) or len(protected_indices) > MAXIMUM_PROTECTED_FRAMES
            or any(isinstance(i, bool) or not isinstance(i, int) or not 0 <= i < len(dimensions)
                   for i in protected_indices)
            or list(protected_indices) != sorted(set(protected_indices))):
        raise ValueError('Protected working image indices must be sorted and bounded')
    protected = set(protected_indices)

    def sizes(factor):
        result = []
        for ordinal, (width, height) in enumerate(dimensions):
            longest = max(width, height)
            floor = min(longest, policy.minimum_long_edge)
            target = (min(longest, MAXIMUM_PROTECTED_LONG_EDGE) if ordinal in protected else
                      max(floor, math.floor(min(longest, policy.maximum_long_edge) * factor)))
            result.append((target, max(1, height * target // width)) if width >= height
                          else (max(1, width * target // height), target))
        return result

    def pixels(output):
        return sum(width * height for width, height in output)

    minimum = sizes(0)
    if pixels(minimum) > policy.maximum_total_pixels:
        raise PreparationError('coverage_budget_exceeded', 'The minimum image resolution exceeds the pixel budget.',
                               minimumRequiredPixels=pixels(minimum), maximumTotalPixels=policy.maximum_total_pixels)
    output = sizes(1)
    if pixels(output) <= policy.maximum_total_pixels:
        return output
    low, high = 0., 1.
    for _ in range(48):
        middle = (low + high) / 2
        if pixels(sizes(middle)) <= policy.maximum_total_pixels:
            low = middle
        else:
            high = middle
    return sizes(low)


def prepare_scan(scan_root, destination, *, profile='fast', uv_unwrap=False, keyframe_selection='even',
                 policy=POLICY, capacity=None, critical_frame_protection=False):
    """Decode one selected frame at a time and write an independent bounded scan."""
    if profile not in ('fast', 'quality'):
        raise ValueError('Processing profile is not supported')
    if policy not in (POLICY, POLICY_V2):
        raise PreparationError('unsupported_preparation_policy', 'The preparation policy is not supported.')
    if not isinstance(critical_frame_protection, bool) or critical_frame_protection and policy != POLICY_V2:
        raise ValueError('Critical frame protection requires an explicit v2 policy')
    settings = working_policy(capacity) if policy == POLICY_V2 else None
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
                                       maximum_long_edge=max(max(size) for size in dimensions), dimensions=dimensions)
    if client is not None and client['policy'] != policy:
        raise ValueError('Client and server preparation policies do not match')
    selection_report = None
    protection = client.get('criticalFrameProtection') if client is not None else None
    actual_protected_indices = []
    if settings is not None:
        from processing_pipeline.frame_selection import select_distinct_frames
        if sum(width * height for width, height in dimensions) > MAX_SOURCE_QUALITY_PIXELS:
            raise PreparationError('coverage_budget_exceeded', 'Source images exceed the bounded decode budget.')
        candidates = [{**source_frames[index], **frame,
                       'path': str(contained_path(root, frame['path'], require_file=True))}
                      for index, frame in enumerate(normalized)]
        if critical_frame_protection and protection is None:
            from processing_pipeline.critical_frame_protection import assess_candidates
            protection = assess_candidates([frame['path'] for frame in candidates])
        indices, selection_report = select_distinct_frames(candidates)
        requested = set(protection['protectedIndices']) if protection is not None else set()
        actual_protected_indices = [index for index in indices if index in requested]
        try:
            output_sizes = working_image_sizes([dimensions[index] for index in indices], settings,
                protected_indices=[ordinal for ordinal, index in enumerate(indices) if index in requested])
        except PreparationError as error:
            error.details.update(originalFrameCount=len(normalized), receivedFrameCount=len(normalized),
                duplicateFrameCount=selection_report['duplicateFrameCount'], selectedFrameCount=len(indices),
                maximumFrames=settings.max_frames, maximumTotalPixels=settings.maximum_total_pixels,
                minimumLongEdge=settings.minimum_long_edge)
            raise
    elif keyframe_selection == 'even':
        indices = selected_frame_indices(len(normalized))
    else:
        from processing_pipeline.keyframe_quality import SELECTION_VERSION, select_quality_keyframes
        if keyframe_selection != SELECTION_VERSION:
            raise ValueError('Unsupported keyframe selection version')
        if sum(width * height for width, height in dimensions) > MAX_SOURCE_QUALITY_PIXELS:
            raise ValueError('Scan exceeds the source quality decode budget; reduce capture resolution or split the scan')
        candidates = [dict(frame, path=str(contained_path(root, frame['path'], require_file=True)))
                      for frame in normalized]
        selected, selection_report = select_quality_keyframes(candidates, MAX_PROCESSING_FRAMES)
        indices = [index for index, _ in selected]
        if not indices:
            raise ValueError('No usable keyframes: capture clearer static texture with balanced exposure')
    if settings is None:
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
        metadata = {'schemaVersion': 1, 'policy': policy, 'policyVersion': 2 if settings else POLICY_VERSION, 'profile': profile,
                    'preparedBy': 'server', 'originalFrameCount': len(normalized), 'selectedFrameCount': len(frames),
                    'selectedIndices': indices, 'processedPixelCount': sum(w * h for w, h in output_sizes),
                    'resizedFrameCount': resized, 'maximumOutputLongEdge': max(max(size) for size in output_sizes),
                    'scaleDigest': hashlib.sha256(json.dumps(scales, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}
        if settings is not None:
            metadata.update(receivedFrameCount=len(normalized), capacityTier=settings.max_frames,
                            duplicateFrameCount=selection_report['duplicateFrameCount'],
                            duplicateGroups=selection_report['duplicateGroups'],
                            selectionVersion=selection_report['version'],
                            maximumTotalPixels=settings.maximum_total_pixels)
            metadata['selectionDigest'] = _digest({'policy': policy, 'capacityTier': settings.max_frames,
                'selectionVersion': selection_report['version'], 'selectedIndices': indices,
                'duplicateGroups': selection_report['duplicateGroups']})
            if protection is not None:
                metadata['criticalFrameProtection'] = {
                    'version': protection['version'], 'riskVersion': protection['riskVersion'],
                    'candidateFrameCount': protection['candidateFrameCount'],
                    'requestedProtectedIndices': protection['protectedIndices'],
                    'protectedIndices': actual_protected_indices,
                    'deduplicatedProtectedIndices': sorted(set(protection['protectedIndices']) - set(indices)),
                }
        manifest = dict(manifest, frames=frames, scanPreparation=metadata)
        if selection_report is not None:
            manifest['sourceKeyframeSelection'] = selection_report
        (output / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True), encoding='utf-8')
        # UV and legacy readers receive the same authoritative per-frame intrinsics.
        (output / 'poses.json').write_text(json.dumps({'frames': frames}), encoding='utf-8')
        calibration = dict(frames[0]['intrinsics'], **frames[0]['image'])
        (output / 'intrinsics.json').write_text(json.dumps(calibration), encoding='utf-8')
        validate_scan(output, uv_unwrap, max_total_frame_pixels=(settings.maximum_total_pixels if settings
                                                               else MAX_TOTAL_FRAME_PIXELS))
        return PreparedScan(output, metadata, client)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
