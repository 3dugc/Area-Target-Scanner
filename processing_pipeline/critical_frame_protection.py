"""Bounded grayscale risk proxy; geometry eligibility remains a separate gate."""
from __future__ import annotations

from PIL import Image

VERSION = 'critical-frame-protection-v1'
RISK_VERSION = 'gray-quality-risk-v1'
MAXIMUM_PROTECTED_FRAMES = 8
MAXIMUM_PROTECTED_LONG_EDGE = 1920
SHARPNESS_THRESHOLD = 16
CONTRAST_THRESHOLD = 20


def capability():
    return {'version': VERSION, 'riskVersion': RISK_VERSION,
            'maximumProtectedFrames': MAXIMUM_PROTECTED_FRAMES,
            'maximumProtectedLongEdge': MAXIMUM_PROTECTED_LONG_EDGE,
            'sharpnessThreshold': SHARPNESS_THRESHOLD, 'contrastThreshold': CONTRAST_THRESHOLD}


def validate_request(value, frame_count):
    fields = {'version', 'riskVersion', 'protectedIndices', 'candidateFrameCount'}
    if (not isinstance(value, dict) or set(value) != fields
            or value['version'] != VERSION or value['riskVersion'] != RISK_VERSION):
        raise ValueError('Critical frame protection metadata is not supported')
    indices, count = value['protectedIndices'], value['candidateFrameCount']
    if (not isinstance(indices, list) or len(indices) > MAXIMUM_PROTECTED_FRAMES
            or any(isinstance(i, bool) or not isinstance(i, int) or not 0 <= i < frame_count for i in indices)
            or indices != sorted(set(indices)) or isinstance(count, bool) or not isinstance(count, int)
            or not len(indices) <= count <= frame_count):
        raise ValueError('Critical frame protection indices or candidate count are invalid')
    return dict(value, protectedIndices=list(indices))


def assess_candidates(paths):
    """Decode one image at a time and rank existing C++ gray-quality outputs."""
    import numpy as np
    from processing_pipeline.native_quality import assess_gray

    candidates = []
    for ordinal, path in enumerate(paths):
        try:
            with Image.open(path) as source:
                with source.convert('L') as gray:
                    gray.thumbnail((MAXIMUM_PROTECTED_LONG_EDGE, MAXIMUM_PROTECTED_LONG_EDGE),
                                   Image.Resampling.LANCZOS)
                    quality = assess_gray(np.asarray(gray, dtype=np.uint8))
        except (OSError, ValueError) as error:
            raise ValueError('Cannot decode frame for critical risk assessment') from error
        if quality is None or quality.rejection_reason == 1:
            raise ValueError('Cannot assess unreadable frame for critical risk protection')
        if (not quality.accepted or quality.laplacian_variance <= SHARPNESS_THRESHOLD
                or quality.gray_standard_deviation <= CONTRAST_THRESHOLD):
            candidates.append((int(bool(quality.accepted)), float(quality.laplacian_variance), ordinal))
    requested = sorted(item[2] for item in sorted(candidates)[:MAXIMUM_PROTECTED_FRAMES])
    return {'version': VERSION, 'riskVersion': RISK_VERSION, 'protectedIndices': requested,
            'candidateFrameCount': len(candidates)}
