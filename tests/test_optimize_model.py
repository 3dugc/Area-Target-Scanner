"""Unit tests for OptimizedPipeline.optimize_model."""

from __future__ import annotations

import os
import json
import struct
from unittest.mock import MagicMock, patch

import pytest

from processing_pipeline.models import ScanInput
from processing_pipeline.optimized_pipeline import OptimizedPipeline


def _make_scan_input(tmp_path) -> ScanInput:
    """Create a minimal ScanInput with a real OBJ file on disk."""
    obj_path = str(tmp_path / "model.obj")
    with open(obj_path, "w") as f:
        f.write("v 0 0 0\n")
    return ScanInput(
        obj_path=obj_path,
        texture_path=str(tmp_path / "texture.jpg"),
        mtl_path=str(tmp_path / "model.mtl"),
        images=[],
        intrinsics=None,
    )


class TestOptimizeModelSuccess:
    """Happy-path: optimizer completes and GLB is downloaded."""

    def test_returns_glb_path(self, tmp_path):
        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        scan_input = _make_scan_input(tmp_path)
        work_dir = str(tmp_path / "work")
        os.makedirs(work_dir)

        mock_client = MagicMock()
        mock_client.optimize.return_value = "task-123"
        mock_client.wait_for_completion.return_value = "completed"

        def fake_download(task_id, output_path):
            return _write_fake_glb(output_path)

        mock_client.download.side_effect = fake_download

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            result = pipeline.optimize_model(scan_input, work_dir)

        assert result == os.path.join(work_dir, "optimized.glb")
        assert os.path.isfile(result)
        assert os.path.getsize(result) > 0

    def test_passes_preset_to_client(self, tmp_path):
        pipeline = OptimizedPipeline(
            optimizer_url="http://fake:3000",
            optimizer_preset="high_quality",
        )
        scan_input = _make_scan_input(tmp_path)
        work_dir = str(tmp_path / "work")
        os.makedirs(work_dir)

        mock_client = MagicMock()
        mock_client.optimize.return_value = "task-456"
        mock_client.wait_for_completion.return_value = "completed"
        mock_client.download.side_effect = lambda tid, p: _write_fake_glb(p)

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            pipeline.optimize_model(scan_input, work_dir)

        mock_client.optimize.assert_called_once_with(
            obj_path=scan_input.obj_path,
            mtl_path=scan_input.mtl_path,
            texture_path=scan_input.texture_path,
            preset="high_quality",
            options={"draco": {"enabled": False}, "texture": {"enabled": False}},
        )


class TestOptimizeModelFailure:
    """Error paths: failed status, empty file, missing file."""

    def test_raises_on_failed_status(self, tmp_path):
        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        scan_input = _make_scan_input(tmp_path)
        work_dir = str(tmp_path / "work")
        os.makedirs(work_dir)

        mock_client = MagicMock()
        mock_client.optimize.return_value = "task-789"
        mock_client.wait_for_completion.return_value = "failed"

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with pytest.raises(RuntimeError, match="模型优化失败"):
                pipeline.optimize_model(scan_input, work_dir)

    def test_raises_on_empty_glb(self, tmp_path):
        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        scan_input = _make_scan_input(tmp_path)
        work_dir = str(tmp_path / "work")
        os.makedirs(work_dir)

        mock_client = MagicMock()
        mock_client.optimize.return_value = "task-000"
        mock_client.wait_for_completion.return_value = "completed"
        # download writes an empty file
        mock_client.download.side_effect = lambda tid, p: _write_empty_file(p)

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with pytest.raises(RuntimeError, match="GLB 文件为空"):
                pipeline.optimize_model(scan_input, work_dir)

    def test_raises_when_download_does_not_create_file(self, tmp_path):
        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        scan_input = _make_scan_input(tmp_path)
        work_dir = str(tmp_path / "work")
        os.makedirs(work_dir)

        mock_client = MagicMock()
        mock_client.optimize.return_value = "task-111"
        mock_client.wait_for_completion.return_value = "completed"
        # download is a no-op — file never created
        mock_client.download.return_value = None

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with pytest.raises(RuntimeError, match="GLB 文件为空"):
                pipeline.optimize_model(scan_input, work_dir)


# -- helpers --

def _write_fake_glb(path: str) -> str:
    payload = json.dumps({"asset": {"version": "2.0"}}).encode()
    payload += b" " * (-len(payload) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sIIII", b"glTF", 2, 20 + len(payload), len(payload), 0x4E4F534A) + payload)
    return path


def _write_empty_file(path: str) -> str:
    with open(path, "wb") as f:
        pass  # 0 bytes
    return path
