"""Flask web service for the Area Target processing pipeline."""

import logging
import json
import tempfile
import multiprocessing
import os
import queue
import shutil
import sqlite3
import threading
import time
import traceback
import uuid
import zipfile
import hashlib
import stat
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from flask import Flask, jsonify, request, send_file, send_from_directory
from web_service.auth import register_auth
from web_service.mobile_api import register_mobile_api

app = Flask(__name__, static_folder="static")
app.config["MAX_CONTENT_LENGTH"] = 512 * 1024 * 1024
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

UPLOAD_DIR = os.environ.get("UPLOAD_DIR", "/tmp/pipeline_uploads")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/tmp/pipeline_outputs")
os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)
register_auth(app, os.path.join(OUTPUT_DIR, "service_auth.sqlite"))

UV_UNWRAP_TIMEOUT_SECONDS = int(os.environ.get("UV_UNWRAP_TIMEOUT_SECONDS", "900"))
UV_UNWRAP_POLL_INTERVAL_SECONDS = 0.25
UV_WORKER_NICE = int(os.environ.get("UV_WORKER_NICE", "10"))
PIPELINE_MAX_WORKERS = int(os.environ.get("PIPELINE_MAX_WORKERS", "1"))
PIPELINE_MAX_QUEUE_SIZE = int(os.environ.get("PIPELINE_MAX_QUEUE_SIZE", "3"))
PIPELINE_CACHE_VERSION = os.environ.get("PIPELINE_CACHE_VERSION", "v3")
STATUS_DB_READ_TTL_SECONDS = float(os.environ.get("STATUS_DB_READ_TTL_SECONDS", "1"))
JOB_RETENTION_HOURS = int(os.environ.get("JOB_RETENTION_HOURS", "24"))
FAILED_JOB_RETENTION_HOURS = int(os.environ.get("FAILED_JOB_RETENTION_HOURS", "6"))
JOB_CLEANUP_INTERVAL_SECONDS = int(
    os.environ.get("JOB_CLEANUP_INTERVAL_SECONDS", "3600")
)
JOB_DB_PATH = os.path.join(OUTPUT_DIR, "jobs.sqlite")
MAX_RESULT_ZIP_BYTES = 512 * 1024 * 1024
MAX_WEB_TOTAL_FRAME_PIXELS = 1_000_000_000

TERMINAL_STATUSES = {"completed", "failed"}
ACTIVE_STATUSES = {"queued", "extracting", "processing"}
VALID_PROFILES = {"fast", "quality"}


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _normalize_job_row(row):
    if row is None:
        return None
    job = dict(row)
    job["uv_unwrap"] = bool(job.get("uv_unwrap"))
    job["profile"] = job.get("profile") or "fast"
    return job


class JobStore:
    """SQLite-backed store for pipeline job metadata."""

    fields = {
        "id",
        "status",
        "step",
        "progress",
        "error",
        "result_zip",
        "uv_unwrap",
        "profile",
        "input_hash",
        "source_job_id",
        "created_at",
        "finished_at",
        "token_hash",
        "error_code",
        "result_sha256",
        "result_size",
        "stage",
    }

    def __init__(self, db_path):
        self.db_path = db_path
        db_dir = os.path.dirname(db_path)
        if db_dir:
            os.makedirs(db_dir, exist_ok=True)
        self._init_db()

    def _connect(self):
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 30000")
        return conn

    def _init_db(self):
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode = WAL")
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    step TEXT,
                    progress INTEGER NOT NULL DEFAULT 0,
                    error TEXT,
                    result_zip TEXT,
                    uv_unwrap INTEGER NOT NULL DEFAULT 0,
                    profile TEXT NOT NULL DEFAULT 'fast',
                    input_hash TEXT,
                    source_job_id TEXT,
                    created_at TEXT NOT NULL,
                    finished_at TEXT
                )
                """
            )
            self._ensure_column(conn, "profile", "TEXT NOT NULL DEFAULT 'fast'")
            self._ensure_column(conn, "input_hash", "TEXT")
            self._ensure_column(conn, "source_job_id", "TEXT")
            for name, definition in (("token_hash", "TEXT"), ("error_code", "TEXT"),
                                     ("result_sha256", "TEXT"), ("result_size", "INTEGER"), ("stage", "TEXT")):
                self._ensure_column(conn, name, definition)
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status)"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_jobs_finished_at ON jobs(finished_at)"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_jobs_input_hash ON jobs(input_hash)"
            )

    @staticmethod
    def _ensure_column(conn, name, definition):
        columns = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(jobs)").fetchall()
        }
        if name not in columns:
            conn.execute(f"ALTER TABLE jobs ADD COLUMN {name} {definition}")

    def _insert(self, conn, job):
        values = {field: job.get(field) for field in self.fields}
        values['uv_unwrap'] = 1 if job.get('uv_unwrap') else 0
        values['profile'] = job.get('profile') or 'fast'
        names = sorted(self.fields)
        conn.execute('INSERT INTO jobs (' + ','.join(names) + ') VALUES (' +
                     ','.join(':' + name for name in names) + ')', values)

    def create(self, job):
        with self._connect() as conn:
            self._insert(conn, job)
        return self.get(job['id'])

    def admit(self, job, capacity):
        """Atomically reconcile identity and reserve a bounded active slot."""
        with self._connect() as conn:
            conn.execute('BEGIN IMMEDIATE')
            existing = conn.execute('SELECT * FROM jobs WHERE id=?', (job['id'],)).fetchone()
            if existing:
                return 'existing', _normalize_job_row(existing)
            count = conn.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','extracting','processing')").fetchone()[0]
            if count >= capacity:
                return 'full', None
            self._insert(conn, job)
        return 'created', self.get(job['id'])

    def update(self, job_id, **kwargs):
        updates = {k: v for k, v in kwargs.items() if k in self.fields and k != "id"}
        if not updates:
            return self.get(job_id)
        if "uv_unwrap" in updates:
            updates["uv_unwrap"] = 1 if updates["uv_unwrap"] else 0

        assignments = ", ".join(f"{key}=:{key}" for key in updates)
        params = dict(updates)
        params["id"] = job_id
        with self._connect() as conn:
            cursor = conn.execute(
                f"UPDATE jobs SET {assignments} WHERE id=:id",
                params,
            )
            if cursor.rowcount == 0:
                return None
        return self.get(job_id)

    def get(self, job_id):
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        return _normalize_job_row(row)

    def list_all(self):
        with self._connect() as conn:
            rows = conn.execute("SELECT * FROM jobs ORDER BY created_at").fetchall()
        return [_normalize_job_row(row) for row in rows]

    def count_statuses(self, statuses):
        if not statuses:
            return 0
        placeholders = ",".join("?" for _ in statuses)
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT COUNT(*) AS count FROM jobs WHERE status IN ({placeholders})",
                tuple(statuses),
            ).fetchone()
        return int(row["count"])

    def find_completed_by_input_hash(self, input_hash):
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM jobs
                WHERE input_hash=? AND token_hash IS NULL AND status='completed' AND result_zip IS NOT NULL
                ORDER BY finished_at DESC, created_at DESC
                LIMIT 1
                """,
                (input_hash,),
            ).fetchone()
        return _normalize_job_row(row)

    def count_result_zip_references(self, result_zip, exclude_job_id=None):
        if not result_zip:
            return 0
        params = [result_zip]
        clause = "result_zip=?"
        if exclude_job_id:
            clause += " AND id<>?"
            params.append(exclude_job_id)
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT COUNT(*) AS count FROM jobs WHERE {clause}",
                params,
            ).fetchone()
        return int(row["count"])

    def list_expired(self, now=None):
        now = now or datetime.now(timezone.utc)
        expired = []
        for job in self.list_all():
            if job["status"] not in TERMINAL_STATUSES:
                continue
            finished_at = _parse_iso(job.get("finished_at")) or _parse_iso(
                job.get("created_at")
            )
            if finished_at is None:
                continue
            retention_hours = (
                FAILED_JOB_RETENTION_HOURS
                if job["status"] == "failed"
                else JOB_RETENTION_HOURS
            )
            age_hours = (now - finished_at).total_seconds() / 3600
            if age_hours >= retention_hours:
                expired.append(job)
        return expired

    def delete(self, job_id):
        with self._connect() as conn:
            conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))

    def mark_interrupted_jobs_failed(self):
        finished_at = _now_iso()
        placeholders = ",".join("?" for _ in ACTIVE_STATUSES)
        params = [
            "failed",
            "服务重启，任务未完成",
            finished_at,
            *ACTIVE_STATUSES,
        ]
        with self._connect() as conn:
            conn.execute(
                f"""
                UPDATE jobs
                SET status=?, error=?, finished_at=?, error_code='processing_interrupted', stage='failed'
                WHERE status IN ({placeholders})
                """,
                params,
            )


job_store = JobStore(JOB_DB_PATH)
job_store.mark_interrupted_jobs_failed()
jobs = {job["id"]: job for job in job_store.list_all()}
_job_cache_read_at = {job_id: time.monotonic() for job_id in jobs}
_jobs_lock = threading.Lock()
_admission_lock = threading.Lock()
pipeline_executor = ThreadPoolExecutor(
    max_workers=max(1, PIPELINE_MAX_WORKERS),
    thread_name_prefix="pipeline",
)


def _update_job(job_id, **kwargs):
    """Thread-safe helper to update job fields in SQLite and memory cache."""
    # Hash exact downloadable bytes once at publication, never on status reads.
    if kwargs.get('status') == 'completed' and kwargs.get('result_zip'):
        kwargs['result_size'] = os.path.getsize(kwargs['result_zip'])
        if kwargs['result_size'] > MAX_RESULT_ZIP_BYTES:
            raise ValueError('The result ZIP exceeds the 512 MiB limit')
        kwargs['result_sha256'] = _sha256_file(kwargs['result_zip'])
    if kwargs.get('status') in ('completed', 'failed'):
        kwargs['stage'] = kwargs['status']
    elif kwargs.get('status') == 'extracting':
        kwargs['stage'] = 'extracting'
    elif kwargs.get('step'):
        step = kwargs['step']
        for marker, stage in [('0/4', 'uv_unwrap'), ('1/4', 'model_optimization'),
                              ('2/4', 'model_optimization'), ('3/4', 'feature_extraction'), ('4/4', 'packaging')]:
            if marker in step:
                kwargs['stage'] = stage
                break
    stored_job = job_store.update(job_id, **kwargs)
    with _jobs_lock:
        if stored_job:
            jobs[job_id] = stored_job
            _job_cache_read_at[job_id] = time.monotonic()
        elif job_id in jobs:
            jobs[job_id].update(kwargs)
            stored_job = dict(jobs[job_id])
            _job_cache_read_at[job_id] = time.monotonic()
    if kwargs:
        snapshot = stored_job or kwargs
        logger.info(
            "job %s update: status=%s step=%s progress=%s",
            job_id,
            snapshot.get("status"),
            snapshot.get("step"),
            snapshot.get("progress"),
        )
    return stored_job


def _create_job(job):
    stored_job = job_store.create(job)
    with _jobs_lock:
        jobs[job["id"]] = stored_job
        _job_cache_read_at[job["id"]] = time.monotonic()
    return stored_job


def _get_job_snapshot(job_id):
    """Return a consistent copy of a job record, preferring SQLite."""
    now = time.monotonic()
    if STATUS_DB_READ_TTL_SECONDS > 0:
        with _jobs_lock:
            job = jobs.get(job_id)
            cached_at = _job_cache_read_at.get(job_id, 0)
            if job and now - cached_at <= STATUS_DB_READ_TTL_SECONDS:
                return dict(job)

    stored_job = job_store.get(job_id)
    if stored_job:
        with _jobs_lock:
            jobs[job_id] = stored_job
            _job_cache_read_at[job_id] = now
        return dict(stored_job)

    with _jobs_lock:
        job = jobs.get(job_id)
        return dict(job) if job else None


def _drop_job_cache(job_id):
    with _jobs_lock:
        jobs.pop(job_id, None)
        _job_cache_read_at.pop(job_id, None)


def _uv_unwrap_worker(scan_root, profile, event_queue):
    """Run UV unwrap in a child process and report progress through a queue."""
    try:
        try:
            if UV_WORKER_NICE > 0:
                os.nice(UV_WORKER_NICE)
        except (AttributeError, OSError):
            pass

        from processing_pipeline.uv_unwrap import uv_unwrap_scan

        def on_progress(step, progress=None):
            event = {"type": "progress", "step": step}
            if progress is not None:
                event["progress"] = progress
            event_queue.put(event)

        stats = uv_unwrap_scan(scan_root, profile=profile, on_progress=on_progress)
        event_queue.put({"type": "done", "stats": stats})
    except BaseException as exc:
        event_queue.put({
            "type": "error",
            "error": str(exc),
            "traceback": traceback.format_exc(),
        })
    finally:
        if hasattr(event_queue, "close"):
            event_queue.close()
        if hasattr(event_queue, "join_thread"):
            event_queue.join_thread()


def _make_uv_unwrap_queue():
    return multiprocessing.Queue()


def _start_uv_unwrap_process(scan_root, profile, event_queue):
    process = multiprocessing.Process(
        target=_uv_unwrap_worker,
        args=(scan_root, profile, event_queue),
        daemon=True,
    )
    process.start()
    return process


def _terminate_process(process):
    if process.is_alive():
        process.terminate()
        process.join(timeout=5)
        if process.is_alive():
            process.kill()
            process.join(timeout=5)


def _run_uv_unwrap_job(
    job_id,
    scan_root,
    profile="fast",
    timeout_seconds=UV_UNWRAP_TIMEOUT_SECONDS,
    poll_interval=UV_UNWRAP_POLL_INTERVAL_SECONDS,
):
    """Run UV unwrap in a child process while keeping the web process responsive."""
    event_queue = _make_uv_unwrap_queue()
    process = _start_uv_unwrap_process(scan_root, profile, event_queue)
    deadline = time.monotonic() + timeout_seconds

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate_process(process)
                raise TimeoutError(
                    f"UV unwrap timed out after {timeout_seconds} seconds"
                )

            try:
                event = event_queue.get(timeout=min(poll_interval, remaining))
            except queue.Empty:
                if process.is_alive():
                    continue
                process.join(timeout=1)
                raise RuntimeError(
                    f"UV unwrap worker exited unexpectedly with code {process.exitcode}"
                )

            event_type = event.get("type")
            if event_type == "progress":
                updates = {"status": "processing"}
                if event.get("step"):
                    updates["step"] = event["step"]
                if event.get("progress") is not None:
                    updates["progress"] = event["progress"]
                _update_job(job_id, **updates)
            elif event_type == "done":
                process.join(timeout=5)
                if process.is_alive():
                    _terminate_process(process)
                    raise RuntimeError("UV unwrap worker did not exit after completion")
                if process.exitcode not in (0, None):
                    logger.info(
                        "job %s uv_unwrap worker reported done with post-completion exit code %s",
                        job_id,
                        process.exitcode,
                    )
                _update_job(
                    job_id,
                    status="processing",
                    step="0/4 UV 纹理展开完成",
                    progress=30,
                )
                return event.get("stats") or {}
            elif event_type == "error":
                process.join(timeout=1)
                if event.get("traceback"):
                    logger.error(
                        "job %s uv_unwrap worker traceback:\n%s",
                        job_id,
                        event["traceback"],
                    )
                raise RuntimeError(event.get("error") or "UV unwrap failed")
    finally:
        _terminate_process(process)
        if hasattr(event_queue, "close"):
            event_queue.close()
        if hasattr(event_queue, "join_thread"):
            event_queue.join_thread()


def find_scan_root(extract_dir):
    """Find the directory containing model.obj and poses.json inside extracted zip."""
    for root, dirs, files in os.walk(extract_dir):
        if "model.obj" in files and ("poses.json" in files or "manifest.json" in files):
            return root
    return None


def safe_extract(zf, extract_dir, max_size=500 * 1024 * 1024):
    """Preflight every member, then stream bounded regular files into a private root."""
    from processing_pipeline.scan_security import contained_path
    entries = zf.infolist()
    if len(entries) > 10000:
        raise ValueError('ZIP contains too many entries')
    total_size = 0
    seen = set()
    destinations = []
    for entry in entries:
        name = entry.filename.rstrip('/') if entry.is_dir() else entry.filename
        target = contained_path(extract_dir, name)
        if target in seen:
            raise ValueError('ZIP contains duplicate paths')
        seen.add(target)
        mode = stat.S_IFMT(entry.external_attr >> 16)
        if mode not in (0, stat.S_IFREG, stat.S_IFDIR) or (mode == stat.S_IFDIR and not entry.is_dir()):
            raise ValueError('ZIP members must be regular files or directories')
        if entry.flag_bits & 1:
            raise ValueError('Encrypted ZIP entries are unsupported')
        total_size += entry.file_size
        if total_size > max_size:
            raise ValueError('ZIP extraction would exceed size limit')
        destinations.append((entry, target))
    actual_size = 0
    for entry, target in destinations:
        if entry.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # Recheck after creating parents, and refuse existing symlinks/files.
        contained_path(extract_dir, entry.filename)
        with zf.open(entry) as source, open(target, 'xb') as output:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                actual_size += len(block)
                if actual_size > max_size:
                    raise ValueError('ZIP extraction would exceed size limit')
                output.write(block)


def _normalize_profile(value):
    profile = (value or "fast").strip().lower()
    if profile not in VALID_PROFILES:
        raise ValueError("profile 必须是 fast 或 quality")
    return profile


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _make_input_hash(zip_hash, profile, uv_unwrap):
    import cv2

    digest = hashlib.sha256()
    # Include both the descriptor producer and preparation policy in cache identity.
    from processing_pipeline.scan_preparation import POLICY_V2
    payload = f"{zip_hash}:{profile}:{int(uv_unwrap)}:{PIPELINE_CACHE_VERSION}:{cv2.__version__}:{POLICY_V2}"
    digest.update(payload.encode("utf-8"))
    return digest.hexdigest()


def _active_job_count():
    return job_store.count_statuses(ACTIVE_STATUSES)


def _queue_capacity_exceeded():
    max_active_jobs = max(1, PIPELINE_MAX_WORKERS) + max(0, PIPELINE_MAX_QUEUE_SIZE)
    return _active_job_count() >= max_active_jobs


def _find_reusable_result(input_hash):
    job = job_store.find_completed_by_input_hash(input_hash)
    if job and job.get("result_zip") and os.path.isfile(job["result_zip"]):
        return job
    return None


def _submit_pipeline_job(job_id, zip_path, uv_unwrap, profile):
    return pipeline_executor.submit(run_pipeline, job_id, zip_path, uv_unwrap, profile)


def _safe_remove_path(path):
    if not path:
        return
    real_path = os.path.realpath(path)
    allowed_roots = [
        os.path.realpath(UPLOAD_DIR),
        os.path.realpath(OUTPUT_DIR),
    ]
    if not any(real_path.startswith(root + os.sep) for root in allowed_roots):
        logger.warning("skip cleanup outside managed dirs: %s", path)
        return
    if os.path.isdir(real_path):
        shutil.rmtree(real_path, ignore_errors=True)
    elif os.path.exists(real_path):
        try:
            os.remove(real_path)
        except OSError:
            logger.exception("failed to remove managed file: %s", real_path)


def _job_file_paths(job):
    job_id = job["id"]
    paths = [
        os.path.join(UPLOAD_DIR, job_id),
        os.path.join(OUTPUT_DIR, job_id),
        os.path.join(OUTPUT_DIR, f"{job_id}.zip"),
    ]
    result_zip = job.get("result_zip")
    if result_zip and result_zip not in paths:
        paths.append(result_zip)
    return paths


def cleanup_expired_jobs(now=None):
    expired_jobs = job_store.list_expired(now=now)
    for job in expired_jobs:
        logger.info("cleaning expired job %s (%s)", job["id"], job["status"])
        for path in _job_file_paths(job):
            if (
                path == job.get("result_zip")
                and job_store.count_result_zip_references(path, exclude_job_id=job["id"])
            ):
                continue
            _safe_remove_path(path)
        job_store.delete(job["id"])
        _drop_job_cache(job["id"])
    return len(expired_jobs)


def _cleanup_loop():
    while True:
        time.sleep(max(60, JOB_CLEANUP_INTERVAL_SECONDS))
        try:
            cleanup_expired_jobs()
        except Exception:
            logger.exception("periodic job cleanup failed")


def _start_cleanup_thread():
    thread = threading.Thread(target=_cleanup_loop, name="job-cleanup", daemon=True)
    thread.start()
    return thread


def run_pipeline(job_id, zip_path, uv_unwrap=False, profile="fast"):
    """Run the optimized pipeline in the bounded pipeline executor."""
    extract_dir = os.path.join(UPLOAD_DIR, job_id, "extracted")
    output_dir = os.path.join(OUTPUT_DIR, job_id)
    work_dir = None
    prepared_dir = None
    preparation = None
    job_started = time.monotonic()

    try:
        # Extract zip
        stage_started = time.monotonic()
        _update_job(job_id, status="extracting", step="解压 ZIP 文件", progress=5)
        os.makedirs(extract_dir, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zf:
            safe_extract(zf, extract_dir)
        logger.info(
            "job %s stage extract completed in %.2fs",
            job_id,
            time.monotonic() - stage_started,
        )

        scan_root = find_scan_root(extract_dir)
        if scan_root is None:
            _update_job(
                job_id,
                status="failed",
                error="ZIP 中未找到 model.obj 和相机数据",
                error_code="invalid_scan",
                finished_at=_now_iso(),
            )
            return

        from processing_pipeline.scan_security import validate_frame_resources
        protected = bool((_get_job_snapshot(job_id) or {}).get('token_hash'))
        if protected:
            from processing_pipeline.scan_security import validate_scan
            from processing_pipeline.scan_preparation import POLICY, POLICY_V2, prepare_scan
            from processing_pipeline.scan_security import load_metadata
            # Admission accepts bounded raw archives; expensive stages see only a working derivative.
            validate_frame_resources(scan_root, max_total_frame_pixels=None)
            source_manifest = os.path.join(scan_root, 'manifest.json')
            client_policy = load_metadata(source_manifest).get('clientPreparation') if os.path.isfile(source_manifest) else None
            mobile_policy = client_policy['policy'] if client_policy is not None else POLICY
            mobile_capacity = client_policy.get('capacityTier') if client_policy is not None else None
            prepared_dir = tempfile.mkdtemp(prefix='prepared_', dir=os.path.join(UPLOAD_DIR, job_id))
            preparation = prepare_scan(scan_root, os.path.join(prepared_dir, 'scan'),
                                       profile=profile, uv_unwrap=uv_unwrap,
                                       policy=mobile_policy, capacity=mobile_capacity)
            scan_root = str(preparation.root)
            validate_scan(scan_root, uv_unwrap, prepare_uv=True,
                          max_total_frame_pixels=preparation.metadata.get('maximumTotalPixels', 200_000_000))
        else:
            validate_frame_resources(scan_root, max_total_frame_pixels=MAX_WEB_TOTAL_FRAME_PIXELS)

        # Optional: UV unwrap (xatlas re-unwrap + texture re-projection)
        if uv_unwrap:
            stage_started = time.monotonic()
            _update_job(
                job_id,
                status="processing",
                step="0/4 UV 纹理展开 (xatlas)",
                progress=6,
            )
            _run_uv_unwrap_job(job_id, scan_root, profile=profile)
            logger.info(
                "job %s stage uv_unwrap completed in %.2fs",
                job_id,
                time.monotonic() - stage_started,
            )

        from processing_pipeline.optimized_pipeline import OptimizedPipeline

        optimizer_url = os.environ.get(
            "MODEL_OPTIMIZER_URL",
            "http://model_optimizer:3000",
        )
        mobile_options = {}
        if preparation is not None and preparation.metadata['policy'] == POLICY_V2:
            mobile_options = {'mobile_preparation_policy': POLICY_V2,
                              'mobile_preparation_capacity': preparation.metadata['capacityTier']}
        pipeline = OptimizedPipeline(
            optimizer_url=optimizer_url,
            processing_profile=profile,
            mobile_feature_limits=protected,
            **mobile_options,
        )
        os.makedirs(output_dir, exist_ok=True)

        # Step 1: Input validation
        stage_started = time.monotonic()
        _update_job(
            job_id,
            status="processing",
            step="1/4 输入验证",
            progress=32 if uv_unwrap else 5,
        )
        scan_input = pipeline.validate_input(scan_root)
        _update_job(job_id, progress=35 if uv_unwrap else 15)
        logger.info(
            "job %s stage validate completed in %.2fs",
            job_id,
            time.monotonic() - stage_started,
        )

        # Step 2: Model optimization
        stage_started = time.monotonic()
        _update_job(job_id, step="2/4 模型优化")
        import trimesh
        work_dir = tempfile.mkdtemp(prefix="pipeline_")
        glb_path = pipeline.optimize_model(scan_input, work_dir)
        _update_job(job_id, progress=55 if uv_unwrap else 35)
        logger.info(
            "job %s stage optimize completed in %.2fs",
            job_id,
            time.monotonic() - stage_started,
        )

        # Load GLB once and convert to trimesh mesh
        scene = trimesh.load(glb_path)
        if isinstance(scene, trimesh.Scene):
            mesh_tri = scene.to_geometry()
        else:
            mesh_tri = scene

        # Step 3: Feature extraction
        stage_started = time.monotonic()
        _update_job(job_id, step="3/4 特征提取")
        features = pipeline.build_feature_database(
            mesh_tri, scan_input.images, scan_input.intrinsics
        )
        _update_job(job_id, progress=75 if uv_unwrap else 60)
        logger.info(
            "job %s stage feature_extract completed in %.2fs",
            job_id,
            time.monotonic() - stage_started,
        )

        # Step 4: Asset bundling
        stage_started = time.monotonic()
        _update_job(job_id, step="4/4 资产打包")
        pipeline.export_asset_bundle(glb_path, mesh_tri, features, output_dir)
        if preparation is not None:
            manifest_path = os.path.join(output_dir, 'manifest.json')
            from processing_pipeline.scan_security import load_metadata
            manifest = load_metadata(manifest_path)
            manifest['scanPreparation'] = preparation.metadata
            prepared_manifest = load_metadata(os.path.join(preparation.root, 'manifest.json'))
            if 'sourceKeyframeSelection' in prepared_manifest:
                # Preserve original-frame diagnostics separately from derivative feature selection.
                manifest['sourceKeyframeSelection'] = prepared_manifest['sourceKeyframeSelection']
            if preparation.client_preparation is not None:
                manifest['clientPreparation'] = preparation.client_preparation
            manifest.setdefault('buildConfiguration', {})['scanPreparation'] = preparation.metadata
            with open(manifest_path, 'w', encoding='utf-8') as destination:
                json.dump(manifest, destination, sort_keys=True)
        _update_job(job_id, progress=90 if uv_unwrap else 80)

        # Create downloadable zip
        result_zip = os.path.join(OUTPUT_DIR, f"{job_id}.zip")
        shutil.make_archive(result_zip.replace(".zip", ""), "zip", output_dir)
        logger.info(
            "job %s stage bundle completed in %.2fs",
            job_id,
            time.monotonic() - stage_started,
        )

        _update_job(
            job_id,
            status="completed",
            step="完成",
            progress=100,
            result_zip=result_zip,
            finished_at=_now_iso(),
        )
        logger.info(
            "job %s completed in %.2fs",
            job_id,
            time.monotonic() - job_started,
        )

    except Exception as e:
        logger.exception("job %s failed", job_id)
        code = getattr(e, 'code', None)
        diagnostic = json.dumps({'message': str(e), 'details': e.details}) if code == 'coverage_budget_exceeded' else str(e)
        _update_job(job_id, status="failed", error=diagnostic,
                    error_code=code if code == 'coverage_budget_exceeded' else 'processing_failed', finished_at=_now_iso())
    finally:
        if work_dir and os.path.isdir(work_dir):
            shutil.rmtree(work_dir, ignore_errors=True)
        if prepared_dir and os.path.isdir(prepared_dir):
            shutil.rmtree(prepared_dir, ignore_errors=True)



@app.route("/")
def index():
    return send_from_directory("static", "index.html")


@app.route("/api/upload", methods=["POST"])
def upload():
    if "file" not in request.files:
        return jsonify({"error": "没有上传文件"}), 400
    f = request.files["file"]
    if not f.filename.endswith(".zip"):
        return jsonify({"error": "请上传 ZIP 文件"}), 400

    try:
        profile = _normalize_profile(request.form.get("profile", "fast"))
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    # 读取 UV 展开选项；默认 fast 档关闭，仅显式 uv_unwrap=1 时开启。
    uv_unwrap = request.form.get("uv_unwrap", "0") == "1"

    job_id = str(uuid.uuid4())[:8]
    job_dir = os.path.join(UPLOAD_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)
    zip_path = os.path.join(job_dir, "upload.zip")
    f.save(zip_path)

    # 验证文件内容是否为有效 ZIP
    if not zipfile.is_zipfile(zip_path):
        os.remove(zip_path)
        os.rmdir(job_dir)
        return jsonify({"error": "上传的文件不是有效的 ZIP 格式"}), 400

    zip_hash = _sha256_file(zip_path)
    input_hash = _make_input_hash(zip_hash, profile, uv_unwrap)
    reusable_job = _find_reusable_result(input_hash)
    if reusable_job:
        _safe_remove_path(job_dir)
        _create_job({
            "id": job_id,
            "status": "completed",
            "step": "完成",
            "progress": 100,
            "error": None,
            "result_zip": reusable_job["result_zip"],
            "uv_unwrap": uv_unwrap,
            "profile": profile,
            "input_hash": input_hash,
            "source_job_id": reusable_job["id"],
            "created_at": _now_iso(),
            "finished_at": _now_iso(),
        })
        return jsonify({"job_id": job_id})

    queued_job = {
        "id": job_id,
        "status": "queued",
        "step": "等待处理",
        "progress": 0,
        "error": None,
        "result_zip": None,
        "uv_unwrap": uv_unwrap,
        "profile": profile,
        "input_hash": input_hash,
        "source_job_id": None,
        "created_at": _now_iso(),
        "finished_at": None,
    }

    outcome, stored_job = job_store.admit(
        queued_job, max(1, PIPELINE_MAX_WORKERS) + max(0, PIPELINE_MAX_QUEUE_SIZE)
    )
    if outcome != 'created':
        _safe_remove_path(job_dir)
        return jsonify({"error": "处理队列已满，请稍后再试"}), 429
    with _jobs_lock:
        jobs[job_id] = stored_job
        _job_cache_read_at[job_id] = time.monotonic()

    _submit_pipeline_job(job_id, zip_path, uv_unwrap, profile)

    return jsonify({"job_id": job_id})


@app.route("/api/status/<job_id>")
def status(job_id):
    job = _get_job_snapshot(job_id)
    if not job or job.get("token_hash"):
        return jsonify({"error": "任务不存在"}), 404
    return jsonify(job)


@app.route("/api/download/<job_id>")
def download(job_id):
    job = _get_job_snapshot(job_id)
    if not job or job.get("token_hash") or job["status"] != "completed":
        return jsonify({"error": "资产包未就绪"}), 404
    if not job.get("result_zip") or not os.path.isfile(job["result_zip"]):
        return jsonify({"error": "资产包文件不存在或已过期"}), 404
    return send_file(
        job["result_zip"],
        as_attachment=True,
        download_name=f"asset_bundle_{job_id}.zip",
    )


register_mobile_api(app, __import__(__name__, fromlist=["app"]))

cleanup_expired_jobs()
_start_cleanup_thread()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
