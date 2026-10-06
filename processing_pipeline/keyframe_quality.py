"""Conservative, versioned quality screening and pose coverage selection.

Thresholds are engineering starting points, not calibrated recognition scores.
Sampling never changes the original pixels, intrinsics, or frame IDs used for PnP.
"""
from dataclasses import dataclass


SELECTION_VERSION = "quality-coverage-v1"


@dataclass(frozen=True)
class FrameQuality:
    sharpness: float
    contrast: float
    mean: float
    saturated_fraction: float
    reason: str | None


def assess_frame_quality(gray):
    from processing_pipeline.native_quality import assess_gray
    quality = assess_gray(gray)
    if quality is None:
        return FrameQuality(0, 0, 0, 1, "unreadable")
    reason = {0: None, 1: "unreadable", 2: "exposure", 3: "exposure", 4: "exposure",
              5: "texture", 6: "blur"}[quality.rejection_reason]
    return FrameQuality(quality.laplacian_variance, quality.gray_standard_deviation,
                        quality.mean_intensity, quality.saturated_fraction, reason)



def select_quality_keyframes(images, max_keyframes):
    """Decode/marshal once, preserving IDs; quality and coverage are core policy."""
    import cv2
    from processing_pipeline.native_quality import select_ordinals
    if max_keyframes is not None and (isinstance(max_keyframes, bool)
                                     or not isinstance(max_keyframes, int) or not 1 <= max_keyframes <= 80):
        raise ValueError("max_keyframes must be an integer in 1..80 or None")
    qualities = [assess_frame_quality(cv2.imread(info["path"], cv2.IMREAD_GRAYSCALE)) for info in images]
    ordinals = select_ordinals(images, qualities, max_keyframes)
    selected = [(index, images[index]) for index in ordinals]
    rejected = [{"imageId": info.get("source_image_id", index), "reason": quality.reason}
                for index, (info, quality) in enumerate(zip(images, qualities)) if quality.reason]
    eligible_count = len(images) - len(rejected)
    report = {"version": SELECTION_VERSION, "inputCount": len(images),
              "eligibleCount": eligible_count,
              "selectedImageIds": [info.get("source_image_id", i) for i, info in selected],
              "rejected": rejected, "budgetDiscardedCount": eligible_count - len(selected)}
    return selected, report
