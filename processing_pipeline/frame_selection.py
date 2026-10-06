"""Conservative pose AND appearance deduplication; never a frame-budget sampler."""
from collections import OrderedDict
from dataclasses import dataclass
import json
import math

import cv2
import numpy as np
from PIL import Image

SELECTION_VERSION = 'pose-visual-dedup-v1'
TRANSLATION_LIMIT = .08
ROTATION_LIMIT_DEGREES = 5.0
THUMBNAIL_LONG_EDGE = 320
MAXIMUM_NEIGHBORS = 32
ANALYSIS_CACHE_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class _Signature:
    pixels: np.ndarray
    points: np.ndarray
    descriptors: np.ndarray | None
    width: int
    height: int
    rank: tuple

    @property
    def nbytes(self):
        return self.pixels.nbytes + self.points.nbytes + (0 if self.descriptors is None else self.descriptors.nbytes)


def _analyze(path):
    try:
        with Image.open(path) as source:
            source.draft('L', (THUMBNAIL_LONG_EDGE, THUMBNAIL_LONG_EDGE))
            with source.convert('L') as gray:
                gray.thumbnail((THUMBNAIL_LONG_EDGE, THUMBNAIL_LONG_EDGE), Image.Resampling.LANCZOS)
                pixels = np.array(gray, dtype=np.uint8)
    except (OSError, ValueError) as error:
        raise ValueError('Cannot decode scan frame for duplicate analysis') from error
    height, width = pixels.shape
    keypoints, descriptors = cv2.ORB_create(nfeatures=500).detectAndCompute(pixels, None)
    if len(keypoints) > 500:
        # OpenCV may return all tied responses beyond nfeatures. Enforce the
        # actual comparison bound while preserving descriptor correspondence.
        indices = sorted(range(len(keypoints)), key=lambda i: (-keypoints[i].response, i))[:500]
        keypoints = [keypoints[index] for index in indices]
        descriptors = descriptors[indices]
    points = np.array([point.pt for point in keypoints], dtype=np.float32).reshape(-1, 2)
    sharpness = float(cv2.Laplacian(pixels, cv2.CV_64F).var())
    clipped = float(np.mean((pixels <= 1) | (pixels >= 254)))
    # Bucket clearly unusable exposure separately so blur's smoothing of clipped
    # pixels cannot beat a sharper, normally exposed representative.
    rank = (int(clipped >= .2), -sharpness, -len(points))
    return _Signature(pixels, points, descriptors, width, height, rank)


class _AnalysisCache:
    def __init__(self, images):
        self.images, self.entries, self.retained_bytes = images, OrderedDict(), 0
        self.peak_bytes = 0

    def get(self, index):
        if index in self.entries:
            self.entries.move_to_end(index)
            return self.entries[index]
        value = _analyze(self.images[index]['path'])
        while self.entries and self.retained_bytes + value.nbytes > ANALYSIS_CACHE_BYTES:
            _, evicted = self.entries.popitem(last=False)
            self.retained_bytes -= evicted.nbytes
        if value.nbytes <= ANALYSIS_CACHE_BYTES:
            self.entries[index] = value
            self.retained_bytes += value.nbytes
            self.peak_bytes = max(self.peak_bytes, self.retained_bytes)
        return value


def _pose(image):
    try:
        pose = np.asarray(image.get('pose'), dtype=np.float64)
        rotation = pose[:3, :3]
        if (pose.shape == (4, 4) and np.isfinite(pose).all()
                and np.allclose(pose[3], [0, 0, 0, 1], atol=1e-6, rtol=0)
                and np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-3, rtol=0)
                and abs(np.linalg.det(rotation) - 1) <= 1e-3):
            return pose
    except (ValueError, TypeError, IndexError):
        pass
    return None


def _partition(image):
    run = image.get('run', image.get('trackingRun', image.get('tracking_run')))
    return json.dumps([run, image.get('imageOrientation')], sort_keys=True, separators=(',', ':'))


def _cell(pose):
    return tuple(math.floor(float(value) / TRANSLATION_LIMIT) for value in pose[:3, 3])


def _near(left, right):
    distance = float(np.linalg.norm(left[:3, 3] - right[:3, 3]))
    if distance > TRANSLATION_LIMIT + 1e-9:
        return None
    cosine = (float(np.trace(left[:3, :3].T @ right[:3, :3])) - 1) / 2
    angle = math.degrees(math.acos(float(np.clip(cosine, -1, 1))))
    return (distance, angle) if angle <= ROTATION_LIMIT_DEGREES else None


def _grid_coverage(points, signature):
    cells = np.floor(points * [4 / signature.width, 4 / signature.height]).astype(np.int32)
    cells = np.clip(cells, 0, 3)
    return len(set(map(tuple, cells)))


def _same_appearance(left, right):
    if min(len(left.points), len(right.points)) < 50:
        return False
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
    forward = matcher.knnMatch(left.descriptors, right.descriptors, k=2)
    reverse = matcher.knnMatch(right.descriptors, left.descriptors, k=2)
    reciprocal = {pair[0].queryIdx: pair[0].trainIdx for pair in reverse
                  if len(pair) == 2 and pair[0].distance < .75 * pair[1].distance}
    matches = [pair[0] for pair in forward if len(pair) == 2
               and pair[0].distance < .75 * pair[1].distance
               and reciprocal.get(pair[0].trainIdx) == pair[0].queryIdx]
    if len(matches) < 50:
        return False
    source = left.points[[match.queryIdx for match in matches]]
    target = right.points[[match.trainIdx for match in matches]]
    homography, mask = cv2.findHomography(source, target, cv2.RANSAC, 2.0)
    if mask is None:
        return False
    inliers = mask.ravel().astype(bool)
    return (int(inliers.sum()) >= 50 and float(inliers.mean()) >= .9
            # A small shared textured patch may yield perfect RANSAC matches
            # even though the rest of both views differs substantially.
            and int(inliers.sum()) / len(left.points) >= .85
            and int(inliers.sum()) / len(right.points) >= .85
            and _grid_coverage(source[inliers], left) >= 9
            and _grid_coverage(target[inliers], right) >= 9
            and _aligned_appearance(left, right, homography))


def _aligned_appearance(left, right, homography):
    """Check the whole view, including regions with too little texture for ORB."""
    try:
        inverse = np.linalg.inv(homography)
    except np.linalg.LinAlgError:
        return False
    left_mask = np.ones(left.pixels.shape, dtype=np.uint8)
    right_mask = np.ones(right.pixels.shape, dtype=np.uint8)
    visible_right = cv2.warpPerspective(left_mask, homography, (right.width, right.height),
                                        flags=cv2.INTER_NEAREST).astype(bool)
    visible_left = cv2.warpPerspective(right_mask, inverse, (left.width, left.height),
                                       flags=cv2.INTER_NEAREST).astype(bool)
    if min(float(visible_left.mean()), float(visible_right.mean())) < .9:
        return False
    aligned = cv2.warpPerspective(left.pixels, homography, (right.width, right.height))
    a = aligned[visible_right].astype(np.float64)
    b = right.pixels[visible_right].astype(np.float64)
    a -= a.mean()
    b -= b.mean()
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    # Correlation tolerates a global exposure change while a changed wall or
    # occluder cannot hide behind perfectly matching points in another region.
    return denominator > 0 and float(np.dot(a, b)) / denominator >= .97


def select_distinct_frames(images):
    """Return source ordinals and auditable direct-to-representative groups.

    Inconclusive quality, exhausted comparisons and non-rigid poses are retained.
    Only fixed kept representatives can remove duplicates, preventing chains.
    """
    cache = _AnalysisCache(images)
    ranks = [cache.get(index).rank for index in range(len(images))]
    poses = [_pose(image) for image in images]
    partitions = [_partition(image) for image in images]
    spatial, groups, selected = {}, {}, []
    comparisons = 0
    for index in sorted(range(len(images)), key=lambda i: (*ranks[i], i)):
        pose, partition = poses[index], partitions[index]
        cell = _cell(pose) if pose is not None else None
        candidates = []
        if cell is not None:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        # Bound pose probing as well as image comparisons in
                        # stationary captures containing many distinct views.
                        key = (partition, cell[0] + dx, cell[1] + dy, cell[2] + dz)
                        for representative in spatial.get(key, ())[:MAXIMUM_NEIGHBORS]:
                            near = _near(pose, poses[representative])
                            if near is not None:
                                candidates.append((*near, representative))
        duplicate_of = None
        for _, _, representative in sorted(candidates)[:MAXIMUM_NEIGHBORS]:
            comparisons += 1
            if _same_appearance(cache.get(index), cache.get(representative)):
                duplicate_of = representative
                break
        if duplicate_of is not None:
            groups.setdefault(duplicate_of, []).append(index)
        else:
            selected.append(index)
            if cell is not None:
                spatial.setdefault((partition, *cell), []).append(index)
    selected.sort()
    report = {'version': SELECTION_VERSION, 'receivedFrameCount': len(images),
              'selectedFrameCount': len(selected), 'duplicateFrameCount': len(images) - len(selected),
              'selectedIndices': selected,
              'duplicateGroups': [{'representativeIndex': index, 'duplicateIndices': sorted(groups[index])}
                                  for index in sorted(groups)],
              'potentialWeakIndices': [index for index in selected
                                       if ranks[index][0] or -ranks[index][2] < 50],
              'visualComparisonCount': comparisons, 'analysisCachePeakBytes': cache.peak_bytes}
    return selected, report
