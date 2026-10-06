"""Balanced feature quotas and the unchanged mobile reader resource contract."""

from __future__ import annotations

from dataclasses import dataclass
from numbers import Integral
from typing import Sequence

import numpy as np

from processing_pipeline.models import FeatureDatabase


@dataclass(frozen=True)
class MobileFeatureBudget:
    profile: str
    orb_total: int
    akaze_total: int
    orb_per_frame: int
    akaze_per_frame: int
    vocabulary_maximum: int


MOBILE_FEATURE_BUDGETS = {
    "quality": MobileFeatureBudget("quality", 160_000, 40_000, 2000, 500, 1000),
    "fast": MobileFeatureBudget("fast", 200_000, 0, 1000, 0, 500),
}


def resolve_mobile_feature_budget(
    value: str | MobileFeatureBudget | None,
) -> MobileFeatureBudget | None:
    """Resolve a supported profile or its immutable, fixed configuration."""
    if value is None:
        return None
    if isinstance(value, str) and value in MOBILE_FEATURE_BUDGETS:
        return MOBILE_FEATURE_BUDGETS[value]
    if isinstance(value, MobileFeatureBudget) and value == MOBILE_FEATURE_BUDGETS.get(value.profile):
        return value
    raise ValueError("Unsupported mobile feature budget")


def _nonnegative_integer(value, name: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, Integral) or value < (1 if positive else 0):
        raise ValueError(f"{name} must be a {'positive' if positive else 'nonnegative'} integer")
    return int(value)


def balanced_quotas(
    demands: Sequence[int], total_budget: int, per_frame_maximum: int, minimum: int = 0,
) -> list[int]:
    """Reserve a minimum, then water-fill quotas in stable source-index order.

    The caller supplies frames ordered by their source index. Frames with little
    demand return unused quota to the active frames; no input frame is removed.
    """
    total_budget = _nonnegative_integer(total_budget, "total_budget")
    per_frame_maximum = _nonnegative_integer(per_frame_maximum, "per_frame_maximum", positive=True)
    minimum = _nonnegative_integer(minimum, "minimum")
    capacity = [min(per_frame_maximum, _nonnegative_integer(n, "demand")) for n in demands]
    quotas = [min(n, minimum) for n in capacity]
    remaining = total_budget - sum(quotas)
    if remaining < 0:
        raise ValueError("feature_budget_exceeded: minimum reservations exceed budget")
    active = [i for i, n in enumerate(capacity) if quotas[i] < n]
    while remaining and active:
        share = max(1, remaining // len(active))
        for i in active:
            grant = min(share, capacity[i] - quotas[i], remaining)
            quotas[i] += grant
            remaining -= grant
            if remaining == 0:
                break
        active = [i for i in active if quotas[i] < capacity[i]]
    return quotas


def validate_mobile_feature_database(
    database: FeatureDatabase, mobile_feature_budget: str | MobileFeatureBudget,
) -> dict[str, int]:
    """Check aligned arrays and mobile producer/reader limits before export."""
    budget = resolve_mobile_feature_budget(mobile_feature_budget)
    if budget is None:
        raise ValueError("A mobile feature budget is required")
    if len(database.keyframes) > 1000:
        raise ValueError("feature_budget_exceeded: native reader permits at most 1000 keyframes")

    orb_total = akaze_total = 0
    seen_ids = set()
    for frame in database.keyframes:
        if (isinstance(frame.image_id, bool) or not isinstance(frame.image_id, Integral)
                or not 0 <= frame.image_id <= 2147483647 or frame.image_id in seen_ids):
            raise ValueError("Mobile keyframe source indices must be unique nonnegative int32")
        seen_ids.add(frame.image_id)
        descriptors = np.asarray(frame.descriptors)
        if descriptors.ndim != 2 or descriptors.dtype != np.uint8 or descriptors.shape[1] != 32:
            raise ValueError("ORB feature arrays must be aligned uint8 correspondences")
        count = len(descriptors)
        keypoints = np.asarray(frame.keypoints, dtype=np.float64)
        points_3d = np.asarray(frame.points_3d, dtype=np.float64)
        if (keypoints.shape != (count, 2) or points_3d.shape != (count, 3)
                or not np.all(np.isfinite(keypoints)) or not np.all(np.isfinite(points_3d))):
            raise ValueError("ORB feature arrays must be aligned finite correspondences")
        if not 20 <= count <= budget.orb_per_frame:
            raise ValueError("feature_budget_exceeded: per-keyframe ORB limit")
        orb_total += count
        if frame.akaze_descriptors is None:
            if frame.akaze_keypoints is not None or frame.akaze_points_3d is not None:
                raise ValueError("AKAZE feature arrays must be aligned")
            continue
        descriptors = np.asarray(frame.akaze_descriptors)
        if descriptors.ndim != 2 or descriptors.dtype != np.uint8 or descriptors.shape[1] != 61:
            raise ValueError("AKAZE feature arrays must be aligned uint8 correspondences")
        count = len(descriptors)
        keypoints = np.asarray(frame.akaze_keypoints, dtype=np.float64)
        points_3d = np.asarray(frame.akaze_points_3d, dtype=np.float64)
        if (keypoints.shape != (count, 2) or points_3d.shape != (count, 3)
                or not np.all(np.isfinite(keypoints)) or not np.all(np.isfinite(points_3d))):
            raise ValueError("AKAZE feature arrays must be aligned finite correspondences")
        if count > budget.akaze_per_frame:
            raise ValueError("feature_budget_exceeded: per-keyframe AKAZE limit")
        akaze_total += count

    if (orb_total > budget.orb_total or akaze_total > budget.akaze_total
            or orb_total + akaze_total > 200_000):
        raise ValueError("feature_budget_exceeded: total feature limit")

    words = 0
    if database.vocabulary is not None:
        vocabulary = np.asarray(database.vocabulary)
        words = len(vocabulary)
        if vocabulary.dtype != np.uint8 or vocabulary.shape != (words, 32):
            raise ValueError("Mobile vocabulary must contain uint8 ORB descriptors")
        if not 1 <= words <= budget.vocabulary_maximum or orb_total * words > 200_000_000:
            raise ValueError("feature_budget_exceeded: vocabulary limit")
        if (database.global_descriptors is None
                or np.asarray(database.global_descriptors).shape != (len(database.keyframes), words)
                or not np.all(np.isfinite(database.global_descriptors))):
            raise ValueError("BoW vectors must align with retained frames and vocabulary")
    elif database.keyframes or database.global_descriptors is not None:
        raise ValueError("A nonempty mobile feature database must have a vocabulary")
    return {"orbFeatureCount": orb_total, "akazeFeatureCount": akaze_total,
            "vocabularySize": words, "retainedKeyframeCount": len(database.keyframes)}
