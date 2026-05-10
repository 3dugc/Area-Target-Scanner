"""Tests for production efficiency profiles."""

import json

import numpy as np


def test_hamming_word_assignment_batches_match_single_batch():
    from processing_pipeline.feature_extraction import _hamming_word_assignment

    rng = np.random.default_rng(42)
    descriptors = rng.integers(0, 255, size=(17, 32), dtype=np.uint8)
    vocabulary = rng.integers(0, 255, size=(9, 32), dtype=np.uint8)

    expected = _hamming_word_assignment(descriptors, vocabulary, batch_size=100)
    actual = _hamming_word_assignment(descriptors, vocabulary, batch_size=3)

    np.testing.assert_array_equal(actual, expected)


def test_optimized_pipeline_fast_profile_passes_low_cost_feature_options(monkeypatch):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline

    captured = {}

    def fake_build_feature_database(images, mesh, intrinsics, **kwargs):
        captured.update(kwargs)
        return "features"

    monkeypatch.setattr(
        OptimizedPipeline,
        "_trimesh_to_o3d",
        staticmethod(lambda mesh: "o3d_mesh"),
    )
    monkeypatch.setattr(
        "processing_pipeline.feature_extraction.build_feature_database",
        fake_build_feature_database,
    )

    pipeline = OptimizedPipeline(processing_profile="fast")
    result = pipeline.build_feature_database(
        mesh_tri="mesh",
        images=[{"path": "frame.jpg"}],
        intrinsics={"fx": 1},
    )

    assert result == "features"
    assert captured["extract_akaze"] is False
    assert captured["orb_nfeatures"] == 1000
    assert captured["bow_k"] == 500
    assert captured["max_keyframes"] == 80
    assert captured["use_minibatch_kmeans"] is True
    assert captured["kmeans_n_init"] == 1
    assert captured["kmeans_max_iter"] == 50


def test_optimized_pipeline_quality_profile_keeps_full_feature_options(monkeypatch):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline

    captured = {}
    monkeypatch.setattr(
        OptimizedPipeline,
        "_trimesh_to_o3d",
        staticmethod(lambda mesh: "o3d_mesh"),
    )
    monkeypatch.setattr(
        "processing_pipeline.feature_extraction.build_feature_database",
        lambda images, mesh, intrinsics, **kwargs: captured.update(kwargs),
    )

    pipeline = OptimizedPipeline(processing_profile="quality")
    pipeline.build_feature_database(mesh_tri="mesh", images=[], intrinsics=None)

    assert captured["extract_akaze"] is True
    assert captured["orb_nfeatures"] == 2000
    assert captured["bow_k"] == 1000
    assert captured["max_keyframes"] is None
    assert captured["use_minibatch_kmeans"] is False
    assert captured["kmeans_n_init"] == 3


def test_uv_unwrap_scan_uses_profile_atlas_size(monkeypatch, tmp_path):
    import processing_pipeline.uv_unwrap as uv_module

    scan_dir = tmp_path / "scan"
    scan_dir.mkdir()
    (scan_dir / "model.obj").write_text("v 0 0 0\n")
    (scan_dir / "poses.json").write_text(json.dumps({"frames": []}))
    (scan_dir / "intrinsics.json").write_text(json.dumps({"width": 1, "height": 1}))
    (scan_dir / "texture.jpg").write_bytes(b"")
    (scan_dir / "model.mtl").write_text("")

    calls = {}
    monkeypatch.setattr(
        uv_module,
        "parse_obj",
        lambda path: (
            np.zeros((3, 3), dtype=np.float32),
            np.zeros((3, 3), dtype=np.float32),
            None,
            np.array([[0, 1, 2]], dtype=np.uint32),
            None,
        ),
    )

    def fake_unwrap(vertices, normals, faces, atlas_size, **kwargs):
        calls["unwrap_atlas"] = atlas_size
        calls["unwrap_profile"] = kwargs["profile"]
        calls["unwrap_max_iterations"] = kwargs["max_iterations"]
        return (
            vertices,
            normals,
            np.zeros((3, 2), dtype=np.float32),
            faces,
            np.array([0, 1, 2]),
        )

    def fake_render(*args, **kwargs):
        calls["render_atlas"] = kwargs["atlas_size"]
        return np.zeros((1, 1, 3), dtype=np.uint8)

    monkeypatch.setattr(uv_module, "unwrap_with_xatlas", fake_unwrap)
    monkeypatch.setattr(uv_module, "render_texture_atlas", fake_render)
    monkeypatch.setattr(uv_module, "write_obj", lambda *args, **kwargs: None)
    monkeypatch.setattr(uv_module, "write_mtl", lambda *args, **kwargs: None)

    stats = uv_module.uv_unwrap_scan(str(scan_dir), profile="fast")

    assert stats["atlas_size"] == 2048
    assert calls == {
        "unwrap_atlas": 2048,
        "unwrap_profile": "fast",
        "unwrap_max_iterations": 1,
        "render_atlas": 2048,
    }


def test_uv_fast_large_mesh_triggers_decimation(monkeypatch):
    import processing_pipeline.uv_unwrap as uv_module

    monkeypatch.setattr(uv_module, "UV_FAST_DECIMATE_THRESHOLD_FACES", 3)
    monkeypatch.setattr(uv_module, "UV_ALLOW_QUALITY_DEGRADE", False)

    assert uv_module._should_decimate_for_profile("fast", 4) is True
    assert uv_module._should_decimate_for_profile("quality", 4) is False


def test_uv_quality_can_opt_in_to_decimation(monkeypatch):
    import processing_pipeline.uv_unwrap as uv_module

    monkeypatch.setattr(uv_module, "UV_FAST_DECIMATE_THRESHOLD_FACES", 3)
    monkeypatch.setattr(uv_module, "UV_ALLOW_QUALITY_DEGRADE", True)

    assert uv_module._should_decimate_for_profile("quality", 4) is True
