"""Quality selection uses original frame IDs and a fixed native feature budget."""
import hashlib

import cv2
import numpy as np
import pytest

from processing_pipeline import feature_extraction
from processing_pipeline.models import FeatureDatabase
from processing_pipeline.optimized_pipeline import OptimizedPipeline


def texture():
    return np.random.default_rng(17).integers(30, 220, (120, 160), dtype=np.uint8)


@pytest.mark.parametrize("gray,reason", [
    (np.zeros((120, 160), np.uint8), "exposure"),
    (np.full((120, 160), 255, np.uint8), "exposure"),
    (np.full((120, 160), 128, np.uint8), "texture"),
    (cv2.GaussianBlur((0.2 * texture() + 0.8 * np.tile(np.linspace(40, 180, 160), (120, 1)))
                     .astype(np.uint8), (0, 0), 5), "blur"),
])
def test_quality_rejects_unusable_pixels_with_reason(gray, reason):
    from processing_pipeline.keyframe_quality import assess_frame_quality
    assert assess_frame_quality(gray).reason == reason


def test_quality_accepts_texture_and_is_independent_of_full_image_resolution():
    from processing_pipeline.keyframe_quality import assess_frame_quality
    small = texture()
    assert assess_frame_quality(small).reason is None
    enlarged = cv2.resize(small, (640, 480), interpolation=cv2.INTER_NEAREST)
    assert assess_frame_quality(enlarged).reason is None


def test_quality_does_not_alias_valid_fine_texture_into_flat_pixels():
    from processing_pipeline.keyframe_quality import assess_frame_quality
    y, x = np.indices((480, 640))
    gray = np.where(((x // 2 + y // 2) % 2) == 0, 50, 200).astype(np.uint8)
    assert len(cv2.ORB_create(nfeatures=2000).detect(gray, None)) > 100
    assert assess_frame_quality(gray).reason is None


def test_quality_preparation_selects_from_full_source_and_carries_source_ids(tmp_path, monkeypatch):
    import io
    import json
    import zipfile
    from processing_pipeline.scan_preparation import prepare_scan
    from tests.test_mobile_scan_preparation import many_frame_zip
    raw = tmp_path / "raw"
    raw.mkdir()
    with zipfile.ZipFile(io.BytesIO(many_frame_zip(count=100, size=(160, 120)))) as archive:
        archive.extractall(raw)
    from PIL import Image
    Image.new("RGB", (8, 8), "gray").save(raw / "texture.jpg")
    (raw / "model.mtl").write_text("newmtl surface\nmap_Kd texture.jpg\n")
    manifest = json.loads((raw / "manifest.json").read_text())
    # Frame 2 is discarded by the old even selection but uniquely covers this region.
    manifest["frames"][2]["transform"][12] = 50
    (raw / "manifest.json").write_text(json.dumps(manifest))
    monkeypatch.setattr(cv2, "imread", lambda path, _: texture() if str(path).endswith("2.jpg")
                        or int(str(path).split("/")[-1].split(".")[0]) % 2 == 0
                        else np.zeros((120, 160), np.uint8))
    prepared = prepare_scan(raw, tmp_path / "prepared", keyframe_selection="quality-coverage-v1")
    assert 2 in prepared.metadata["selectedIndices"]
    assert prepared.metadata["selectedFrameCount"] == 50
    assert all(index % 2 == 0 for index in prepared.metadata["selectedIndices"])
    scan = OptimizedPipeline().validate_input(str(prepared.root))
    assert [image["source_image_id"] for image in scan.images] == prepared.metadata["selectedIndices"]


def test_selection_keeps_good_spatial_views_instead_of_duplicate_and_bad_frames(monkeypatch):
    from processing_pipeline.keyframe_quality import select_quality_keyframes
    frames = []
    for index, x in enumerate([0, 0, 0, 0, 4, 8]):
        pose = np.eye(4)
        pose[0, 3] = x
        frames.append(dict(path=str(index), pose=pose))
    monkeypatch.setattr(cv2, "imread", lambda path, _: np.zeros((120, 160), np.uint8)
                        if path == "3" else texture())
    selected, report = select_quality_keyframes(frames, 3)
    assert [i for i, _ in selected] == [0, 4, 5]
    assert report["rejected"] == [{"imageId": 3, "reason": "exposure"}]
    assert report["selectedImageIds"] == [0, 4, 5]
    assert selected == select_quality_keyframes(frames, 3)[0]


def test_selection_includes_orientation_coverage_and_never_exceeds_budget(monkeypatch):
    from processing_pipeline.keyframe_quality import select_quality_keyframes
    frames = []
    for angle in [0, 0, 0, np.pi / 2]:
        pose = np.eye(4)
        pose[:3, :3] = [[np.cos(angle), 0, np.sin(angle)], [0, 1, 0],
                       [-np.sin(angle), 0, np.cos(angle)]]
        frames.append(dict(path="texture", pose=pose))
    monkeypatch.setattr(cv2, "imread", lambda *_: texture())
    selected, _ = select_quality_keyframes(frames, 2)
    assert [i for i, _ in selected] == [0, 3]
    with pytest.raises(ValueError):
        select_quality_keyframes(frames, 0)


def test_source_quality_decode_budget_is_checked_before_decoding(tmp_path, monkeypatch):
    import io
    import zipfile
    import processing_pipeline.scan_preparation as preparation
    from tests.test_mobile_scan_preparation import many_frame_zip
    raw = tmp_path / "raw"
    raw.mkdir()
    with zipfile.ZipFile(io.BytesIO(many_frame_zip(count=3, size=(80, 60)))) as archive:
        archive.extractall(raw)
    monkeypatch.setattr(preparation, "MAX_SOURCE_QUALITY_PIXELS", 10, raising=False)
    monkeypatch.setattr(cv2, "imread", lambda *_: pytest.fail("budget must be checked before image decode"))
    destination = tmp_path / "prepared"
    with pytest.raises(ValueError, match="quality decode budget"):
        preparation.prepare_scan(raw, destination, uv_unwrap=True, keyframe_selection="quality-coverage-v1")
    assert not destination.exists()


def test_v2_policy_cannot_reuse_previous_preparation_cache(monkeypatch):
    from web_service import app as app_module
    monkeypatch.setattr(app_module, "PIPELINE_CACHE_VERSION", "v2")
    previous = hashlib.sha256("scan:quality:0:v2".encode()).hexdigest()
    assert app_module._make_input_hash("scan", "quality", False) != previous


def test_optimized_profiles_enable_versioned_selection_without_changing_limits(monkeypatch):
    calls = []
    monkeypatch.setattr(OptimizedPipeline, "_trimesh_to_o3d", lambda self, mesh: mesh)
    monkeypatch.setattr(feature_extraction, "build_feature_database",
                        lambda *args, **kwargs: calls.append(kwargs) or FeatureDatabase(keyframes=[]))
    OptimizedPipeline(mobile_feature_limits=True).build_feature_database(None, [])
    assert calls[-1]["keyframe_selection"] == "quality-coverage-v1"
    assert calls[-1]["max_keyframes"] == 80
    assert calls[-1]["orb_nfeatures"] == 2000
    assert calls[-1]["max_akaze_features"] == 500


def test_new_selection_cannot_reuse_previous_v2_feature_cache(monkeypatch):
    from web_service import app as app_module
    from processing_pipeline.scan_preparation import POLICY_V2
    monkeypatch.setattr(app_module, "PIPELINE_CACHE_VERSION", "v3")
    previous = hashlib.sha256(
        f"scan:quality:0:0:v3:{cv2.__version__}:{POLICY_V2}".encode()).hexdigest()
    assert app_module._make_input_hash("scan", "quality", False) != previous


def test_new_selection_cannot_reuse_old_opencv5_feature_cache(monkeypatch):
    from web_service import app as app_module
    monkeypatch.setattr(app_module, "PIPELINE_CACHE_VERSION", "v3")
    previous = hashlib.sha256(f"scan:quality:0:v3:{cv2.__version__}".encode()).hexdigest()
    assert app_module._make_input_hash("scan", "quality", False) != previous
