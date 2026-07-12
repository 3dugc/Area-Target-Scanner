"""Unit tests for OptimizedPipeline.validate_input."""

from __future__ import annotations

import json
import os

import numpy as np
import pytest

from processing_pipeline.optimized_pipeline import OptimizedPipeline


def _make_scan_dir(
    tmp_path,
    *,
    include_obj=True,
    include_texture=True,
    include_mtl=True,
    include_poses=True,
    frames=None,
    include_intrinsics=False,
    intrinsics_data=None,
):
    """Helper to create a scan directory with the specified files."""
    scan_dir = str(tmp_path / "scan")
    os.makedirs(scan_dir, exist_ok=True)

    if include_obj:
        open(os.path.join(scan_dir, "model.obj"), "w").close()
    if include_texture:
        open(os.path.join(scan_dir, "texture.jpg"), "w").close()
    if include_mtl:
        open(os.path.join(scan_dir, "model.mtl"), "w").close()

    if include_poses:
        if frames is None:
            frames = [
                {
                    "imageFile": "images/frame_0000.jpg",
                    "transform": list(range(16)),
                }
            ]
        poses = {"frames": frames}
        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump(poses, f)

    if include_intrinsics:
        data = intrinsics_data or {"fx": 500, "fy": 500, "cx": 320, "cy": 240}
        with open(os.path.join(scan_dir, "intrinsics.json"), "w") as f:
            json.dump(data, f)

    return scan_dir


class TestValidateInputSuccess:
    """Tests for successful validation."""

    def test_returns_scan_input_with_correct_paths(self, tmp_path):
        scan_dir = _make_scan_dir(tmp_path)
        pipeline = OptimizedPipeline()
        result = pipeline.validate_input(scan_dir)

        assert result.obj_path == os.path.join(scan_dir, "model.obj")
        assert result.texture_path == os.path.join(scan_dir, "texture.jpg")
        assert result.mtl_path == os.path.join(scan_dir, "model.mtl")

    def test_parses_transform_column_major(self, tmp_path):
        data = list(range(16))
        scan_dir = _make_scan_dir(
            tmp_path,
            frames=[{"imageFile": "images/f.jpg", "transform": data}],
        )
        pipeline = OptimizedPipeline()
        result = pipeline.validate_input(scan_dir)

        expected = np.array(data, dtype=np.float64).reshape(4, 4, order="F")
        np.testing.assert_array_equal(result.images[0]["pose"], expected)

    def test_intrinsics_none_when_absent(self, tmp_path):
        scan_dir = _make_scan_dir(tmp_path, include_intrinsics=False)
        pipeline = OptimizedPipeline()
        result = pipeline.validate_input(scan_dir)
        assert result.intrinsics is None

    def test_intrinsics_loaded_when_present(self, tmp_path):
        intrinsics = {"fx": 600, "fy": 600, "cx": 320, "cy": 240}
        scan_dir = _make_scan_dir(
            tmp_path, include_intrinsics=True, intrinsics_data=intrinsics
        )
        pipeline = OptimizedPipeline()
        result = pipeline.validate_input(scan_dir)
        assert result.intrinsics == intrinsics

    def test_multiple_frames(self, tmp_path):
        frames = [
            {"imageFile": f"images/frame_{i:04d}.jpg", "transform": list(range(16))}
            for i in range(3)
        ]
        scan_dir = _make_scan_dir(tmp_path, frames=frames)
        pipeline = OptimizedPipeline()
        result = pipeline.validate_input(scan_dir)
        assert len(result.images) == 3


class TestValidateInputMissingFiles:
    """Tests for missing required files."""

    @pytest.mark.parametrize(
        "missing_kwarg",
        ["include_obj", "include_texture", "include_mtl", "include_poses"],
    )
    def test_raises_file_not_found_for_missing_file(self, tmp_path, missing_kwarg):
        kwargs = {missing_kwarg: False}
        scan_dir = _make_scan_dir(tmp_path, **kwargs)
        pipeline = OptimizedPipeline()
        with pytest.raises(FileNotFoundError, match="必需文件缺失"):
            pipeline.validate_input(scan_dir)


class TestValidateInputEmptyFrames:
    """Tests for empty frames in poses.json."""

    def test_raises_value_error_for_empty_frames(self, tmp_path):
        scan_dir = _make_scan_dir(tmp_path, frames=[])
        pipeline = OptimizedPipeline()
        with pytest.raises(ValueError, match="不包含任何帧"):
            pipeline.validate_input(scan_dir)
