"""Versioned capability-authorized mobile job contract."""
from __future__ import annotations

import hashlib
import hmac
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid
import zipfile
from datetime import datetime, timedelta, timezone

from flask import jsonify, request, send_file
from werkzeug.exceptions import HTTPException, RequestEntityTooLarge

from processing_pipeline.scan_security import validate_scan, image_dimensions, load_metadata, contained_path
from processing_pipeline.scan_preparation import processing_requirements, validate_client_preparation

TOKEN_PATTERN = re.compile(r'Bearer ([0-9a-f]{64})\Z')
STAGES = {'queued', 'extracting', 'uv_unwrap', 'model_optimization', 'feature_extraction', 'packaging', 'completed', 'failed'}
MESSAGES = {'queued': 'Waiting for processing.', 'extracting': 'Extracting scan data.',
            'uv_unwrap': 'Building model texture.', 'model_optimization': 'Optimizing the model.',
            'feature_extraction': 'Extracting visual features.', 'packaging': 'Packaging the result.',
            'completed': 'Result is ready to download.', 'failed': 'Processing did not complete.'}
ERRORS = {'processing_interrupted': ('The service restarted before processing finished. Submit a new task.', False),
          'processing_failed': ('Processing failed. Submit a new task to retry.', True),
          'invalid_scan': ('The scan is missing valid model or camera data.', False)}


class APIError(Exception):
    def __init__(self, status, code, message, retryable=False):
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


def token_hash():
    match = TOKEN_PATTERN.fullmatch(request.headers.get('Authorization', ''))
    if not match:
        raise APIError(401, 'missing_or_invalid_token', 'A valid task token is required.')
    return hashlib.sha256(match.group(1).encode('ascii')).hexdigest()


def canonical_id(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def authorized_job(server, job_id, digest):
    job = server._get_job_snapshot(job_id) if canonical_id(job_id) else None
    if not job or not job.get('token_hash') or not hmac.compare_digest(job['token_hash'], digest):
        raise APIError(404, 'job_not_found', 'The task was not found.')
    return job


def expiry(server, job):
    if job['status'] not in server.TERMINAL_STATUSES:
        return None
    finished = server._parse_iso(job.get('finished_at')) or server._parse_iso(job.get('created_at'))
    if not finished:
        return None
    hours = server.FAILED_JOB_RETENTION_HOURS if job['status'] == 'failed' else server.JOB_RETENTION_HOURS
    return (finished + timedelta(hours=hours)).isoformat()


def dto(server, job):
    status = job['status']
    stage = job.get('stage')
    if status in ('queued', 'extracting', 'completed', 'failed'):
        stage = status
    elif stage not in STAGES:
        stage = 'model_optimization'
    expires_at = expiry(server, job)
    error = result = None
    if status == 'failed':
        code = job.get('error_code')
        if code not in ERRORS:
            code = 'processing_failed'
        message, retryable = ERRORS[code]
        error = {'code': code, 'message': message, 'retryable': retryable}
    elif status == 'completed' and job.get('result_sha256') and job.get('result_size') is not None:
        result = {'format': 'area-target-bundle', 'filename': f"asset_bundle_{job['id']}.zip",
                  'size_bytes': int(job['result_size']), 'sha256': job['result_sha256'],
                  'url': f"/api/v1/jobs/{job['id']}/result", 'expires_at': expires_at}
    return {'job_id': job['id'], 'status': status, 'progress': max(0, min(100, int(job.get('progress') or 0))),
            'stage': stage, 'message': MESSAGES[stage], 'profile': job['profile'], 'uv_unwrap': bool(job['uv_unwrap']),
            'created_at': job['created_at'], 'finished_at': job.get('finished_at'), 'expires_at': expires_at,
            'error': error, 'result': result}


def reconcile(server, job, digest, fingerprint):
    if not job.get('token_hash') or not hmac.compare_digest(job['token_hash'], digest):
        raise APIError(404, 'job_not_found', 'The task was not found.')
    if not hmac.compare_digest(job.get('input_hash') or '', fingerprint):
        raise APIError(409, 'submission_conflict', 'This task ID was submitted with different data or options.')
    return jsonify(dto(server, job)), 200


def register_mobile_api(app, server):
    @app.errorhandler(APIError)
    def api_error(error):
        response = jsonify({'error': {'code': error.code, 'message': error.message, 'retryable': error.retryable}})
        response.status_code = error.status
        if error.status == 429:
            response.headers['Retry-After'] = '10'
        return response

    @app.errorhandler(RequestEntityTooLarge)
    def too_large(error):
        if request.path.startswith('/api/v1/'):
            return api_error(APIError(413, 'payload_too_large', 'The upload exceeds the 512 MiB request limit.'))
        return jsonify({'error': 'Upload exceeds the request size limit.'}), 413

    @app.errorhandler(HTTPException)
    def http_error(error):
        if request.path.startswith('/api/v1/'):
            code = 'job_not_found' if error.code == 404 else 'invalid_request'
            return api_error(APIError(error.code or 500, code, 'The requested resource was not found.' if error.code == 404 else 'The request is invalid.'))
        return error

    @app.errorhandler(Exception)
    def internal_error(error):
        server.logger.exception('HTTP request failed')
        if request.path.startswith('/api/v1/'):
            return api_error(APIError(500, 'internal_error', 'The service could not complete the request.', True))
        return jsonify({'error': 'Internal server error'}), 500

    @app.after_request
    def private_cache(response):
        if request.path.startswith('/api/v1/jobs'):
            response.headers['Cache-Control'] = 'no-store'
        return response

    @app.get('/api/v1/processing-requirements')
    def requirements():
        return jsonify(processing_requirements(maximum_request_bytes=app.config['MAX_CONTENT_LENGTH']))

    @app.post('/api/v1/jobs')
    def submit():
        digest = token_hash()
        job_id = request.headers.get('Idempotency-Key')
        if not canonical_id(job_id):
            raise APIError(400, 'invalid_request', 'Idempotency-Key must be a canonical lowercase UUID.')
        # Deny an identity owned by another capability before reading its upload.
        existing = server._get_job_snapshot(job_id)
        if existing and (not existing.get('token_hash') or not hmac.compare_digest(existing['token_hash'], digest)):
            raise APIError(404, 'job_not_found', 'The task was not found.')
        if (len(request.files.getlist('file')) != 1 or set(request.files) != {'file'}
                or any(len(request.form.getlist(key)) != 1 for key in request.form)
                or set(request.form) - {'profile', 'uv_unwrap'}):
            raise APIError(400, 'invalid_request', 'Submit one scan ZIP and supported processing options.')
        upload = request.files['file']
        profile = request.form.get('profile', 'fast')
        unwrap = request.form.get('uv_unwrap', '1')
        if not upload.filename or not upload.filename.lower().endswith('.zip') or profile not in server.VALID_PROFILES or unwrap not in ('0', '1'):
            raise APIError(400, 'invalid_request', 'A ZIP, fast or quality profile, and uv_unwrap=0 or 1 are required.')
        uv_unwrap = unwrap == '1'
        incoming = tempfile.mkdtemp(prefix='.incoming-', dir=server.UPLOAD_DIR)
        try:
            zip_path = os.path.join(incoming, 'upload.zip')
            upload.save(zip_path)
            payload_hash = server._sha256_file(zip_path)
            # Submission equality is independent of future pipeline/cache versions.
            fingerprint = hashlib.sha256(f'{payload_hash}:{profile}:{unwrap}'.encode()).hexdigest()
            if existing:
                return reconcile(server, existing, digest, fingerprint)
            extract_dir = os.path.join(incoming, 'preflight')
            os.makedirs(extract_dir)
            try:
                with zipfile.ZipFile(zip_path) as archive:
                    server.safe_extract(archive, extract_dir)
            except (ValueError, OSError, zipfile.BadZipFile, NotImplementedError, RuntimeError) as error:
                raise APIError(400, 'invalid_archive', 'The ZIP is invalid or exceeds the archive limits.') from error
            try:
                scan_root = server.find_scan_root(extract_dir)
                if scan_root is None:
                    raise ValueError('No scan root')
                frames = validate_scan(scan_root, uv_unwrap, max_total_frame_pixels=None)
                manifest_path = Path(scan_root) / 'manifest.json'
                if manifest_path.is_file():
                    manifest = load_metadata(manifest_path)
                    if manifest.get('clientPreparation') is not None:
                        dimensions = [image_dimensions(contained_path(scan_root, frame['path'], require_file=True)) for frame in frames]
                        validate_client_preparation(manifest['clientPreparation'], frame_count=len(frames),
                                                    actual_pixels=sum(w * h for w, h in dimensions),
                                                    maximum_long_edge=max(max(size) for size in dimensions))
            except (ValueError, OSError, TypeError, KeyError, RecursionError) as error:
                raise APIError(400, 'invalid_scan', 'The scan must contain a valid model, keyframe images, and camera data.') from error
            shutil.rmtree(extract_dir)
            job = {'id': job_id, 'status': 'queued', 'step': '等待处理', 'stage': 'queued', 'progress': 0,
                   'error': None, 'error_code': None, 'result_zip': None, 'uv_unwrap': uv_unwrap, 'profile': profile,
                   'input_hash': fingerprint, 'source_job_id': None, 'token_hash': digest,
                   'created_at': server._now_iso(), 'finished_at': None}
            with server._admission_lock:
                outcome, stored = server.job_store.admit(job, max(1, server.PIPELINE_MAX_WORKERS) + max(0, server.PIPELINE_MAX_QUEUE_SIZE))
                if outcome == 'existing':
                    return reconcile(server, stored, digest, fingerprint)
                if outcome == 'full':
                    raise APIError(429, 'queue_full', 'The processing queue is full. Try again shortly.', True)
                with server._jobs_lock:
                    server.jobs[job_id] = stored
                    server._job_cache_read_at.pop(job_id, None)
                destination = os.path.join(server.UPLOAD_DIR, job_id)
                try:
                    os.rename(incoming, destination)
                    server._submit_pipeline_job(job_id, os.path.join(destination, 'upload.zip'), uv_unwrap, profile)
                except Exception:
                    server._update_job(job_id, status='failed', error_code='processing_failed', finished_at=server._now_iso())
                    raise
            return jsonify(dto(server, server._get_job_snapshot(job_id))), 202
        finally:
            if os.path.isdir(incoming):
                shutil.rmtree(incoming, ignore_errors=True)

    @app.get('/api/v1/jobs/<job_id>', endpoint='mobile_status')
    def status(job_id):
        job = authorized_job(server, job_id, token_hash())
        return jsonify(dto(server, job))

    @app.get('/api/v1/jobs/<job_id>/result')
    def result(job_id):
        job = authorized_job(server, job_id, token_hash())
        if job['status'] != 'completed':
            raise APIError(409, 'result_not_ready', 'The task result is not ready.')
        expires_at = expiry(server, job)
        if (not expires_at or datetime.fromisoformat(expires_at) <= datetime.now(timezone.utc)
                or not job.get('result_zip') or not os.path.isfile(job['result_zip'])):
            raise APIError(410, 'result_expired', 'The server result is no longer available.')
        return send_file(job['result_zip'], as_attachment=True, download_name=f'asset_bundle_{job_id}.zip',
                         mimetype='application/zip', conditional=False)

    @app.get('/api/v1/openapi.json')
    def openapi():
        return send_file(Path(__file__).with_name('openapi.json'), mimetype='application/json')
