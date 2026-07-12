"""Tests for durable web pipeline job orchestration."""

import io
import hashlib
import os
import zipfile
from datetime import datetime, timedelta, timezone


def _job(job_id, **overrides):
    job = {
        "id": job_id,
        "status": "queued",
        "step": "等待处理",
        "progress": 0,
        "error": None,
        "result_zip": None,
        "uv_unwrap": False,
        "profile": "fast",
        "input_hash": None,
        "source_job_id": None,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "finished_at": None,
    }
    job.update(overrides)
    return job


def _zip_bytes():
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        zf.writestr("scan/model.obj", "v 0 0 0\n")
        zf.writestr("scan/poses.json", "{}")
    buffer.seek(0)
    return buffer


def _isolate_app_store(monkeypatch, tmp_path):
    import web_service.app as app_module

    upload_dir = tmp_path / "uploads"
    output_dir = tmp_path / "outputs"
    upload_dir.mkdir()
    output_dir.mkdir()

    store = app_module.JobStore(str(output_dir / "jobs.sqlite"))
    monkeypatch.setattr(app_module, "UPLOAD_DIR", str(upload_dir))
    monkeypatch.setattr(app_module, "OUTPUT_DIR", str(output_dir))
    monkeypatch.setattr(app_module, "job_store", store)
    monkeypatch.setattr(app_module, "jobs", {})
    monkeypatch.setattr(app_module, "_job_cache_read_at", {})
    return app_module, store, upload_dir, output_dir


def test_job_store_persists_jobs(tmp_path):
    import web_service.app as app_module

    db_path = tmp_path / "jobs.sqlite"
    store = app_module.JobStore(str(db_path))
    store.create(_job("persisted", status="completed", progress=100))

    reloaded = app_module.JobStore(str(db_path))
    job = reloaded.get("persisted")

    assert job["status"] == "completed"
    assert job["progress"] == 100
    assert job["uv_unwrap"] is False
    assert job["profile"] == "fast"


def test_update_job_syncs_sqlite_and_memory(monkeypatch, tmp_path):
    app_module, store, _, _ = _isolate_app_store(monkeypatch, tmp_path)

    app_module._create_job(_job("sync"))
    app_module._update_job(
        "sync",
        status="processing",
        step="2/4 模型优化",
        progress=40,
    )

    assert store.get("sync")["step"] == "2/4 模型优化"
    assert store.get("sync")["progress"] == 40
    assert app_module.jobs["sync"]["status"] == "processing"


def test_status_prefers_sqlite_over_memory(monkeypatch, tmp_path):
    app_module, store, _, _ = _isolate_app_store(monkeypatch, tmp_path)
    monkeypatch.setattr(app_module, "STATUS_DB_READ_TTL_SECONDS", 0)

    store.create(_job("source", status="completed", progress=100))
    app_module.jobs["source"] = _job("source", status="queued", progress=0)

    job = app_module._get_job_snapshot("source")

    assert job["status"] == "completed"
    assert job["progress"] == 100


def test_status_uses_memory_cache_within_ttl(monkeypatch, tmp_path):
    app_module, store, _, _ = _isolate_app_store(monkeypatch, tmp_path)
    monkeypatch.setattr(app_module, "STATUS_DB_READ_TTL_SECONDS", 60)

    app_module._create_job(_job("cached", status="queued", progress=0))
    store.update("cached", status="completed", progress=100)

    job = app_module._get_job_snapshot("cached")

    assert job["status"] == "queued"
    assert job["progress"] == 0


def test_upload_creates_queued_job_and_submits_executor(monkeypatch, tmp_path):
    app_module, store, _, _ = _isolate_app_store(monkeypatch, tmp_path)
    submitted = []

    def fake_submit(job_id, zip_path, uv_unwrap, profile):
        submitted.append((job_id, zip_path, uv_unwrap, profile))

    monkeypatch.setattr(app_module, "_submit_pipeline_job", fake_submit)
    client = app_module.app.test_client()

    response = client.post(
        "/api/upload",
        data={
            "file": (_zip_bytes(), "scan.zip"),
            "uv_unwrap": "1",
            "profile": "quality",
        },
        content_type="multipart/form-data",
    )

    assert response.status_code == 200
    job_id = response.get_json()["job_id"]
    stored_job = store.get(job_id)
    assert stored_job["status"] == "queued"
    assert stored_job["uv_unwrap"] is True
    assert stored_job["profile"] == "quality"
    assert submitted == [
        (
            job_id,
            os.path.join(app_module.UPLOAD_DIR, job_id, "upload.zip"),
            True,
            "quality",
        )
    ]


def test_upload_rejects_when_queue_is_full(monkeypatch, tmp_path):
    app_module, _, upload_dir, _ = _isolate_app_store(monkeypatch, tmp_path)
    monkeypatch.setattr(app_module, "PIPELINE_MAX_WORKERS", 1)
    monkeypatch.setattr(app_module, "PIPELINE_MAX_QUEUE_SIZE", 3)
    for i in range(4):
        app_module._create_job(_job(f"active_{i}", status="queued"))

    response = app_module.app.test_client().post(
        "/api/upload",
        data={"file": (_zip_bytes(), "scan.zip")},
        content_type="multipart/form-data",
    )

    assert response.status_code == 429
    assert response.get_json()["error"] == "处理队列已满，请稍后再试"
    assert sorted(os.listdir(upload_dir)) == []


def test_upload_reuses_completed_result_by_input_hash(monkeypatch, tmp_path):
    app_module, store, upload_dir, output_dir = _isolate_app_store(monkeypatch, tmp_path)
    submitted = []
    monkeypatch.setattr(
        app_module,
        "_submit_pipeline_job",
        lambda *args: submitted.append(args),
    )
    zip_buffer = _zip_bytes()
    zip_bytes = zip_buffer.getvalue()
    zip_hash = hashlib.sha256(zip_bytes).hexdigest()
    input_hash = app_module._make_input_hash(zip_hash, "fast", False)
    result_zip = output_dir / "source.zip"
    result_zip.write_text("asset")
    store.create(
        _job(
            "source",
            status="completed",
            progress=100,
            result_zip=str(result_zip),
            input_hash=input_hash,
            finished_at=datetime.now(timezone.utc).isoformat(),
        )
    )

    response = app_module.app.test_client().post(
        "/api/upload",
        data={"file": (io.BytesIO(zip_bytes), "scan.zip")},
        content_type="multipart/form-data",
    )

    assert response.status_code == 200
    job_id = response.get_json()["job_id"]
    stored_job = store.get(job_id)
    assert stored_job["status"] == "completed"
    assert stored_job["result_zip"] == str(result_zip)
    assert stored_job["source_job_id"] == "source"
    assert submitted == []
    assert not (upload_dir / job_id).exists()


def test_submit_pipeline_uses_executor(monkeypatch):
    import web_service.app as app_module

    calls = []

    class FakeExecutor:
        def submit(self, fn, *args):
            calls.append((fn, args))
            return "future"

    monkeypatch.setattr(app_module, "pipeline_executor", FakeExecutor())

    assert app_module._submit_pipeline_job("job", "/tmp/upload.zip", False, "fast") == "future"
    assert calls == [(app_module.run_pipeline, ("job", "/tmp/upload.zip", False, "fast"))]


def test_cleanup_expired_jobs_removes_terminal_files_only(monkeypatch, tmp_path):
    app_module, store, upload_dir, output_dir = _isolate_app_store(monkeypatch, tmp_path)
    monkeypatch.setattr(app_module, "JOB_RETENTION_HOURS", 24)
    monkeypatch.setattr(app_module, "FAILED_JOB_RETENTION_HOURS", 6)
    now = datetime.now(timezone.utc)
    old_finished = (now - timedelta(hours=30)).isoformat()
    recent_finished = (now - timedelta(hours=1)).isoformat()

    expired = _job(
        "expired",
        status="completed",
        progress=100,
        result_zip=str(output_dir / "expired.zip"),
        finished_at=old_finished,
    )
    active = _job(
        "active",
        status="processing",
        progress=50,
        finished_at=None,
    )
    recent_failed = _job(
        "recent_failed",
        status="failed",
        error="boom",
        finished_at=recent_finished,
    )
    for job in (expired, active, recent_failed):
        store.create(job)
        (upload_dir / job["id"]).mkdir()
        (output_dir / job["id"]).mkdir()
    (output_dir / "expired.zip").write_text("zip")

    cleaned = app_module.cleanup_expired_jobs(now=now)

    assert cleaned == 1
    assert store.get("expired") is None
    assert not (upload_dir / "expired").exists()
    assert not (output_dir / "expired").exists()
    assert not (output_dir / "expired.zip").exists()
    assert store.get("active")["status"] == "processing"
    assert (upload_dir / "active").exists()
    assert store.get("recent_failed")["status"] == "failed"
