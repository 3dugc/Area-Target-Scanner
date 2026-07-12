"""Tests for process-isolated UV unwrap orchestration."""

import os
import queue
import zipfile
from unittest.mock import MagicMock, patch

import pytest


def _job(job_id):
    return {
        "id": job_id,
        "status": "queued",
        "step": "等待处理",
        "progress": 0,
        "error": None,
        "result_zip": None,
        "uv_unwrap": True,
        "profile": "fast",
        "input_hash": None,
        "source_job_id": None,
        "created_at": "2026-01-01T00:00:00+00:00",
        "finished_at": None,
    }


class FakeQueue:
    def __init__(self, events=None):
        self.events = list(events or [])
        self.closed = False
        self.joined = False

    def get(self, timeout=None):
        if self.events:
            return self.events.pop(0)
        raise queue.Empty

    def close(self):
        self.closed = True

    def join_thread(self):
        self.joined = True


class FakeProcess:
    def __init__(self, alive=False, exitcode=0):
        self._alive = alive
        self.exitcode = exitcode
        self.terminated = False
        self.killed = False
        self.join_count = 0

    def is_alive(self):
        return self._alive

    def join(self, timeout=None):
        self.join_count += 1

    def terminate(self):
        self.terminated = True
        self._alive = False

    def kill(self):
        self.killed = True
        self._alive = False


def _build_minimal_scan_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("scan/model.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
        zf.writestr("scan/model.mtl", "newmtl textured_material\n")
        zf.writestr("scan/texture.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 64)
        zf.writestr(
            "scan/poses.json",
            '{"frames": [{"imageFile": "images/frame_0000.jpg", '
            '"transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,2,1]}]}',
        )
        zf.writestr(
            "scan/intrinsics.json",
            '{"fx":1,"fy":1,"cx":0,"cy":0,"width":1,"height":1}',
        )
        zf.writestr("scan/images/frame_0000.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 64)


def test_uv_unwrap_subprocess_progress_updates_job(monkeypatch):
    import web_service.app as app_module

    job_id = "uv_progress"
    app_module.jobs[job_id] = _job(job_id)
    fake_queue = FakeQueue([
        {"type": "progress", "step": "0/4 UV 纹理展开 (解析 OBJ)", "progress": 8},
        {"type": "progress", "step": "0/4 UV 纹理展开 (纹理投影)", "progress": 24},
        {"type": "done", "stats": {"vertex_count": 12, "face_count": 4}},
    ])
    fake_process = FakeProcess(alive=False, exitcode=0)

    monkeypatch.setattr(app_module, "_make_uv_unwrap_queue", lambda: fake_queue)
    monkeypatch.setattr(
        app_module,
        "_start_uv_unwrap_process",
        lambda scan_root, profile, event_queue: fake_process,
    )

    try:
        stats = app_module._run_uv_unwrap_job(
            job_id, "/tmp/scan", timeout_seconds=5, poll_interval=0.01
        )

        assert stats == {"vertex_count": 12, "face_count": 4}
        assert app_module.jobs[job_id]["step"] == "0/4 UV 纹理展开完成"
        assert app_module.jobs[job_id]["progress"] == 30
        assert fake_queue.closed
        assert fake_queue.joined
    finally:
        app_module.jobs.pop(job_id, None)


def test_uv_unwrap_done_event_wins_over_nonzero_exit(monkeypatch):
    import web_service.app as app_module

    job_id = "uv_done_nonzero"
    app_module.jobs[job_id] = _job(job_id)
    fake_queue = FakeQueue([
        {"type": "done", "stats": {"atlas_size": 2048}},
    ])
    fake_process = FakeProcess(alive=False, exitcode=1)

    monkeypatch.setattr(app_module, "_make_uv_unwrap_queue", lambda: fake_queue)
    monkeypatch.setattr(
        app_module,
        "_start_uv_unwrap_process",
        lambda scan_root, profile, event_queue: fake_process,
    )

    try:
        stats = app_module._run_uv_unwrap_job(
            job_id, "/tmp/scan", timeout_seconds=5, poll_interval=0.01
        )

        assert stats == {"atlas_size": 2048}
        assert app_module.jobs[job_id]["step"] == "0/4 UV 纹理展开完成"
        assert app_module.jobs[job_id]["progress"] == 30
    finally:
        app_module.jobs.pop(job_id, None)


def test_uv_unwrap_subprocess_timeout_terminates_worker(monkeypatch):
    import web_service.app as app_module

    job_id = "uv_timeout"
    app_module.jobs[job_id] = _job(job_id)
    fake_queue = FakeQueue()
    fake_process = FakeProcess(alive=True, exitcode=None)

    monkeypatch.setattr(app_module, "_make_uv_unwrap_queue", lambda: fake_queue)
    monkeypatch.setattr(
        app_module,
        "_start_uv_unwrap_process",
        lambda scan_root, profile, event_queue: fake_process,
    )

    try:
        with pytest.raises(TimeoutError, match="UV unwrap timed out"):
            app_module._run_uv_unwrap_job(
                job_id, "/tmp/scan", timeout_seconds=0.01, poll_interval=0.001
            )
        assert fake_process.terminated
    finally:
        app_module.jobs.pop(job_id, None)


def test_run_pipeline_uv_unwrap_uses_process_wrapper(tmp_path):
    import trimesh as _trimesh_mod
    import web_service.app as app_module

    job_id = "uv_wrapper"
    zip_path = tmp_path / "scan.zip"
    _build_minimal_scan_zip(zip_path)
    app_module.jobs[job_id] = _job(job_id)

    mock_pipeline = MagicMock()
    mock_pipeline.validate_input.return_value = MagicMock(images=[], intrinsics=None)
    mock_pipeline.optimize_model.return_value = str(tmp_path / "optimized.glb")
    mock_mesh = MagicMock()

    with patch.object(
        app_module, "_run_uv_unwrap_job", return_value={"vertex_count": 3}
    ) as unwrap_job, patch(
        "processing_pipeline.optimized_pipeline.OptimizedPipeline",
        return_value=mock_pipeline,
    ), patch.object(
        _trimesh_mod, "load", return_value=mock_mesh
    ), patch.object(
        _trimesh_mod, "Scene", new=type("_FakeScene", (), {})
    ):
        try:
            app_module.run_pipeline(job_id, str(zip_path), uv_unwrap=True, profile="fast")

            unwrap_job.assert_called_once()
            assert unwrap_job.call_args.kwargs["profile"] == "fast"
            assert app_module.jobs[job_id]["status"] == "completed"
            assert app_module.jobs[job_id]["progress"] == 100
            assert mock_pipeline.validate_input.called
        finally:
            app_module.jobs.pop(job_id, None)
            output_dir = os.path.join(app_module.OUTPUT_DIR, job_id)
            if os.path.isdir(output_dir):
                import shutil

                shutil.rmtree(output_dir, ignore_errors=True)


def test_run_pipeline_uv_unwrap_failure_sets_failed_status(tmp_path):
    import web_service.app as app_module

    job_id = "uv_failure"
    zip_path = tmp_path / "scan.zip"
    _build_minimal_scan_zip(zip_path)
    app_module.jobs[job_id] = _job(job_id)

    with patch.object(app_module, "_run_uv_unwrap_job", side_effect=RuntimeError("uv boom")):
        try:
            app_module.run_pipeline(job_id, str(zip_path), uv_unwrap=True, profile="fast")

            assert app_module.jobs[job_id]["status"] == "failed"
            assert "uv boom" in app_module.jobs[job_id]["error"]
        finally:
            app_module.jobs.pop(job_id, None)
