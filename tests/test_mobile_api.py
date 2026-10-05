"""Public mobile API contract, resource limits, and task capability isolation."""
import hashlib
import io
import json
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from PIL import Image

TOKEN = 'a' * 64
JOB_ID = '4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1'


def scan_zip(*, manifest=True, textured=True, image_ref='images/f.png', extra=None):
    image = io.BytesIO()
    Image.new('RGB', (32, 24), 'gray').save(image, format='PNG')
    frame = {'imageFile': image_ref, 'transform': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
             'imageOrientation': 'landscapeRight', 'image': {'width': 32, 'height': 24},
             'intrinsics': {'fx': 30, 'fy': 30, 'cx': 16, 'cy': 12}}
    entries = {'model.obj': b'v 0 0 -1\nv 1 0 -1\nv 0 1 -1\nf 1 2 3\n', 'images/f.png': image.getvalue()}
    if manifest:
        entries['manifest.json'] = json.dumps({'schemaVersion': 1, 'coordinateSystem': 'arkit-world',
            'matrixLayout': 'arkit-column-major', 'units': 'meters', 'frames': [frame]}).encode()
    else:
        entries['poses.json'] = json.dumps({'frames': [frame]}).encode()
        entries['intrinsics.json'] = json.dumps(frame['intrinsics']).encode()
    if textured:
        entries.update({'model.mtl': b'newmtl test\nmap_Kd texture.jpg\n', 'texture.jpg': image.getvalue()})
    entries.update(extra or {})
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return output.getvalue()


@pytest.fixture
def api(monkeypatch, tmp_path):
    import web_service.app as server
    from tests.service_auth_helpers import authenticate_test_clients
    authenticate_test_clients(monkeypatch, tmp_path, server.app)
    uploads, outputs = tmp_path / 'uploads', tmp_path / 'outputs'
    uploads.mkdir(); outputs.mkdir()
    monkeypatch.setattr(server, 'UPLOAD_DIR', str(uploads))
    monkeypatch.setattr(server, 'OUTPUT_DIR', str(outputs))
    monkeypatch.setattr(server, 'job_store', server.JobStore(str(outputs / 'jobs.sqlite')))
    monkeypatch.setattr(server, 'jobs', {})
    monkeypatch.setattr(server, '_job_cache_read_at', {})
    monkeypatch.setattr(server, 'STATUS_DB_READ_TTL_SECONDS', 0)
    monkeypatch.setattr(server, 'PIPELINE_MAX_WORKERS', 1)
    monkeypatch.setattr(server, 'PIPELINE_MAX_QUEUE_SIZE', 3)
    submissions = []
    monkeypatch.setattr(server, '_submit_pipeline_job', lambda *args: submissions.append(args))
    return server, server.app.test_client(), submissions


def headers(job_id=JOB_ID, token=TOKEN):
    return {'Authorization': 'Bearer ' + token, 'Idempotency-Key': job_id}


def submit(client, payload=None, job_id=JOB_ID, token=TOKEN, **options):
    return client.post('/api/v1/jobs', headers=headers(job_id, token), data={
        'file': (io.BytesIO(payload if payload is not None else scan_zip()), 'scan.zip'),
        'profile': 'fast', 'uv_unwrap': '1', **options})


def test_create_protected_job_returns_sanitized_durable_identity(api):
    server, client, submissions = api
    response = submit(client)
    assert response.status_code == 202
    job = response.get_json()
    assert set(job) == {'job_id', 'status', 'progress', 'stage', 'message', 'profile', 'uv_unwrap',
                        'created_at', 'finished_at', 'expires_at', 'error', 'result'}
    assert job['job_id'] == JOB_ID and job['stage'] == 'queued' and job['progress'] == 0
    assert job['error'] is None and job['result'] is None and job['uv_unwrap'] is True
    assert len(submissions) == 1
    stored = server.job_store.get(JOB_ID)
    assert stored['token_hash'] == hashlib.sha256(TOKEN.encode()).hexdigest()
    assert TOKEN not in str(stored)


def test_retries_do_not_submit_twice_and_changed_submission_conflicts(api):
    server, client, submissions = api
    payload = scan_zip()
    assert submit(client, payload).status_code == 202
    assert submit(client, payload).status_code == 200
    for options in ({'profile': 'quality'}, {'uv_unwrap': '0'}):
        response = submit(client, payload, **options)
        assert response.status_code == 409 and response.json['error']['code'] == 'submission_conflict'
    assert submit(client, scan_zip(extra={'note.txt': b'different'})).status_code == 409
    assert submit(client, payload, token='b' * 64).status_code == 404
    assert len(submissions) == 1


@pytest.mark.parametrize('token', ['', 'A' * 64, 'a' * 63, 'x' * 64])
def test_missing_or_noncanonical_token_is_401(api, token):
    _, client, _ = api
    for method, path in [('get', '/api/v1/jobs/' + JOB_ID), ('get', '/api/v1/jobs/' + JOB_ID + '/result'), ('post', '/api/v1/jobs')]:
        response = getattr(client, method)(path, headers=headers(token=token))
        assert response.status_code == 401
        assert response.json == {'error': {'code': 'missing_or_invalid_token', 'message': 'A valid task token is required.', 'retryable': False}}


@pytest.mark.parametrize('job_id', ['../escape', '4F619A9C-19CD-45D2-BFD7-C2F82BA5CFA1', 'not-an-id', JOB_ID.replace('-', '')])
def test_submission_requires_canonical_uuid(api, job_id):
    _, client, _ = api
    response = submit(client, job_id=job_id)
    assert response.status_code == 400 and response.json['error']['code'] == 'invalid_request'


def test_auth_isolation_and_legacy_routes(api):
    server, client, _ = api
    assert submit(client).status_code == 202
    for path in ['/api/v1/jobs/' + JOB_ID, '/api/v1/jobs/' + JOB_ID + '/result']:
        assert client.get(path, headers=headers(token='b' * 64)).status_code == 404
        assert client.get(path).status_code == 401
    assert client.get('/api/status/' + JOB_ID).status_code == 404
    assert client.get('/api/download/' + JOB_ID).status_code == 404
    assert client.get('/api/v1/jobs/' + str(uuid.uuid4()), headers=headers()).status_code == 404
    response = client.get('/api/v1/jobs/' + JOB_ID + '/result', headers=headers())
    assert response.status_code == 409 and response.json['error']['code'] == 'result_not_ready'


def complete(server):
    result = __import__('pathlib').Path(server.OUTPUT_DIR) / (JOB_ID + '.zip')
    result.write_bytes(b'PK protected exact result bytes')
    server._update_job(JOB_ID, status='completed', progress=100, result_zip=str(result), finished_at=datetime.now(timezone.utc).isoformat())
    return result


def test_result_metadata_matches_exact_download_without_status_rehash(api, monkeypatch):
    server, client, _ = api
    submit(client)
    result_file = complete(server)
    expected = hashlib.sha256(result_file.read_bytes()).hexdigest()
    def no_rehash(*args):
        raise AssertionError('Status must use persisted metadata')
    monkeypatch.setattr(server, '_sha256_file', no_rehash)
    response = client.get('/api/v1/jobs/' + JOB_ID, headers=headers())
    job = response.json
    assert job['stage'] == 'completed' and job['error'] is None
    result = job['result']
    assert set(result) == {'format', 'filename', 'size_bytes', 'sha256', 'url', 'expires_at'}
    assert result['sha256'] == expected and result['size_bytes'] == result_file.stat().st_size
    assert result['format'] == 'area-target-bundle' and result['url'] == '/api/v1/jobs/' + JOB_ID + '/result'
    assert result['expires_at'] == job['expires_at']
    download = client.get(result['url'], headers=headers())
    assert download.status_code == 200 and download.data == result_file.read_bytes()
    assert 'attachment' in download.headers['Content-Disposition']


def test_expired_result_is_gone_and_failed_errors_are_safe(api):
    server, client, _ = api
    submit(client); complete(server)
    old = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    server._update_job(JOB_ID, finished_at=old)
    response = client.get('/api/v1/jobs/' + JOB_ID + '/result', headers=headers())
    assert response.status_code == 410 and response.json['error']['code'] == 'result_expired'
    server._update_job(JOB_ID, status='failed', error='secret traceback /private/scan')
    job = client.get('/api/v1/jobs/' + JOB_ID, headers=headers()).json
    assert job['stage'] == 'failed' and job['result'] is None
    assert job['error']['code'] == 'processing_failed'
    assert '/private' not in json.dumps(job) and 'traceback' not in json.dumps(job)


def test_restart_preserves_capability_and_marks_interrupted(api):
    server, client, _ = api
    submit(client)
    restored = server.JobStore(server.job_store.db_path)
    restored.mark_interrupted_jobs_failed()
    assert restored.get(JOB_ID)['token_hash'] == hashlib.sha256(TOKEN.encode()).hexdigest()
    server.job_store = restored
    job = client.get('/api/v1/jobs/' + JOB_ID, headers=headers()).json
    assert job['status'] == 'failed' and job['error']['code'] == 'processing_interrupted'
    assert 'new task' in job['error']['message']


def test_legacy_cache_cannot_reuse_protected_result(api):
    server, client, submissions = api
    payload = scan_zip()
    submit(client, payload); complete(server)
    response = client.post('/api/upload', data={'file': (io.BytesIO(payload), 'scan.zip'), 'uv_unwrap': '1'})
    assert response.status_code == 200
    legacy = server.job_store.get(response.json['job_id'])
    assert legacy['status'] == 'queued' and legacy['source_job_id'] is None
    assert len(submissions) == 2


def test_concurrent_identical_submissions_admit_one_job(api):
    server, _, submissions = api
    payload = scan_zip()
    def post(_):
        with server.app.test_client() as client:
            return submit(client, payload).status_code
    with ThreadPoolExecutor(max_workers=6) as pool:
        statuses = list(pool.map(post, range(6)))
    assert sorted(statuses) == [200, 200, 200, 200, 200, 202]
    assert len(submissions) == 1 and len(server.job_store.list_all()) == 1


def test_atomic_queue_capacity_across_parallel_admission(api, monkeypatch):
    server, _, submissions = api
    monkeypatch.setattr(server, 'PIPELINE_MAX_QUEUE_SIZE', 0)
    payload = scan_zip()
    def post(_):
        with server.app.test_client() as client:
            response = submit(client, payload, job_id=str(uuid.uuid4()))
            if response.status_code == 429:
                assert response.headers['Retry-After'] == '10'
                assert response.json['error']['code'] == 'queue_full'
            return response.status_code
    with ThreadPoolExecutor(max_workers=6) as pool:
        statuses = list(pool.map(post, range(6)))
    assert sorted(statuses) == [202, 429, 429, 429, 429, 429]
    assert len(submissions) == 1


@pytest.mark.parametrize('options', [{'profile': 'bad'}, {'uv_unwrap': 'true'}])
def test_invalid_options(api, options):
    _, client, _ = api
    response = submit(client, **options)
    assert response.status_code == 400 and response.json['error']['code'] == 'invalid_request'


@pytest.mark.parametrize('payload,code', [(b'not a zip', 'invalid_archive'), (scan_zip(image_ref='../outside.png'), 'invalid_scan'),
    (scan_zip(extra={'../outside': b'x'}), 'invalid_archive'), (scan_zip(extra={'model.obj': b''}), 'invalid_scan')])
def test_invalid_uploads_are_rejected_before_queue(api, payload, code):
    server, client, submissions = api
    response = submit(client, payload)
    assert response.status_code == 400 and response.json['error']['code'] == code
    assert submissions == [] and server.job_store.list_all() == []


def test_legacy_and_manifest_first_untextured_scans_are_accepted_with_uv(api):
    _, client, submissions = api
    assert submit(client, scan_zip(textured=False)).status_code == 202
    assert submit(client, scan_zip(manifest=False), job_id=str(uuid.uuid4())).status_code == 202
    assert len(submissions) == 2


def test_request_size_error_has_structured_envelope(api, monkeypatch):
    server, client, _ = api
    monkeypatch.setitem(server.app.config, 'MAX_CONTENT_LENGTH', 64)
    response = submit(client)
    assert response.status_code == 413 and response.json['error']['code'] == 'payload_too_large'


def test_openapi_requires_service_login_and_describes_both_credentials(api):
    _, client, _ = api
    response = client.get('/api/v1/openapi.json')
    assert response.status_code == 200
    assert '/api/v1/jobs' in response.json['paths']
    assert response.json['components']['securitySchemes']['TaskToken']['scheme'] == 'bearer'
    assert response.json['components']['securitySchemes']['ServiceSession']['name'] == 'X-Area-Target-Session'
    assert response.json['paths']['/api/v1/jobs']['post']['security'] == [{'ServiceSession': [], 'TaskToken': []}]
    unauthenticated = client.get('/api/v1/openapi.json', headers={'X-Area-Target-Session': ''})
    assert unauthenticated.status_code == 401


def test_legacy_admission_shares_atomic_capacity(api, monkeypatch):
    import threading
    server, _, submissions = api
    monkeypatch.setattr(server, 'PIPELINE_MAX_QUEUE_SIZE', 0)
    original_count = server._active_job_count
    barrier = threading.Barrier(3)
    def synchronized_count():
        count = original_count()
        barrier.wait(timeout=5)
        return count
    monkeypatch.setattr(server, '_active_job_count', synchronized_count)
    payload = scan_zip()
    def post(_):
        with server.app.test_client() as client:
            return client.post('/api/upload', data={'file': (io.BytesIO(payload), 'scan.zip')}).status_code
    with ThreadPoolExecutor(max_workers=3) as pool:
        statuses = list(pool.map(post, range(3)))
    assert sorted(statuses) == [200, 429, 429]
    assert len(submissions) == 1


def test_browser_processing_checks_pixels_before_model_decoder(api, monkeypatch):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline
    import processing_pipeline.scan_security as boundary
    server, client, submissions = api
    payload = scan_zip()
    response = client.post('/api/upload', data={'file': (io.BytesIO(payload), 'scan.zip'), 'uv_unwrap': '0'})
    assert response.status_code == 200
    monkeypatch.setattr(boundary, 'MAX_IMAGE_PIXELS', 10)
    monkeypatch.setattr(OptimizedPipeline, 'optimize_model', lambda *_: pytest.fail('Oversized keyframes reached the model decoder'))
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(response.json['job_id'])
    assert job['status'] == 'failed' and 'pixel' in job['error']


def test_result_publication_refuses_bundle_over_client_limit(api, monkeypatch):
    server, client, _ = api
    submit(client)
    monkeypatch.setattr(server, 'MAX_RESULT_ZIP_BYTES', 16, raising=False)
    with pytest.raises(ValueError, match='result'):
        complete(server)
    assert server.job_store.get(JOB_ID)['status'] == 'queued'
