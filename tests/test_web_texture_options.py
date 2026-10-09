"""Durable, default-off texture compression selection at the web worker boundary."""
import hashlib
import io
import re
import sqlite3
from pathlib import Path

import cv2
import numpy as np
import pytest

from tests.test_mobile_api import api as mobile_api_fixture
from tests.test_mobile_api import scan_zip, submit
from tests.test_mobile_scan_preparation import install_worker_boundary_fakes
from tests.test_web_job_store import _job

api = mobile_api_fixture


def upload(client, payload, value=None):
    fields = {'file': (io.BytesIO(payload), 'scan.zip'), 'uv_unwrap': '0'}
    if value is not None:
        fields['texture_compression'] = value
    return client.post('/api/upload', data=fields)


@pytest.mark.parametrize('value, expected', [(None, False), ('0', False), ('false', False), ('1', True), ('true', True)])
def test_web_texture_selection_defaults_off_and_is_durable(api, value, expected):
    server, client, submissions = api
    response = upload(client, scan_zip(), value)
    assert response.status_code == 200
    job_id = response.json['job_id']
    reloaded = server.JobStore(server.job_store.db_path)
    assert reloaded.get(job_id)['texture_compression'] is expected
    assert client.get('/api/status/' + job_id).json['texture_compression'] is expected
    assert len(submissions[0]) == 4, 'The existing mobile worker submission contract stays positional'


@pytest.mark.parametrize('value', ['', 'yes', '2', 'not-a-boolean'])
def test_web_rejects_invalid_texture_selection_before_admission(api, value):
    server, client, submissions = api
    response = upload(client, scan_zip(), value)
    assert response.status_code == 400
    assert 'texture_compression' in response.json['error']
    assert not submissions and not server.job_store.list_all()
    assert not list(Path(server.UPLOAD_DIR).iterdir())


def test_existing_database_migrates_historical_texture_selection_to_true_once(tmp_path):
    import web_service.app as server
    path = tmp_path / 'legacy.sqlite'
    with sqlite3.connect(path) as conn:
        conn.execute('''CREATE TABLE jobs (
            id TEXT PRIMARY KEY, status TEXT NOT NULL, step TEXT,
            progress INTEGER NOT NULL DEFAULT 0, error TEXT, result_zip TEXT,
            uv_unwrap INTEGER NOT NULL DEFAULT 0, profile TEXT NOT NULL DEFAULT 'fast',
            input_hash TEXT, source_job_id TEXT, created_at TEXT NOT NULL, finished_at TEXT)''')
        conn.execute("INSERT INTO jobs (id,status,created_at) VALUES ('old','completed','2026-10-08T00:00:00+00:00')")
    store = server.JobStore(str(path))
    assert store.get('old')['texture_compression'] is True
    with sqlite3.connect(path) as conn:
        columns = {row[1]: row for row in conn.execute('PRAGMA table_info(jobs)')}
    assert columns['texture_compression'][3:5] == (1, '0')
    store.create(_job('new'))
    assert store.get('new')['texture_compression'] is False
    store.update('old', texture_compression=True)
    assert server.JobStore(str(path)).get('old')['texture_compression'] is True
    store.update('old', texture_compression=False)
    assert server.JobStore(str(path)).get('old')['texture_compression'] is False


def test_texture_flag_separates_cache_and_invalidates_pre_option_results(api, monkeypatch):
    from processing_pipeline.scan_preparation import POLICY_V2
    server, _, _ = api
    monkeypatch.setattr(server, 'PIPELINE_CACHE_VERSION', 'v3')
    previous = hashlib.sha256(f'source:fast:0:v3:{cv2.__version__}:{POLICY_V2}'.encode()).hexdigest()
    default = server._make_input_hash('source', 'fast', False)
    explicit_off = server._make_input_hash('source', 'fast', False, texture_compression=False)
    explicit_on = server._make_input_hash('source', 'fast', False, texture_compression=True)
    assert default == explicit_off
    assert explicit_off != explicit_on
    assert previous not in {default, explicit_on}, 'Operator cache namespace overrides must still avoid old WebP results'


@pytest.mark.parametrize('source_enabled', [False, True])
def test_web_cannot_reuse_other_texture_selection(api, source_enabled):
    server, client, submissions = api
    payload = scan_zip()
    source_hash = server._make_input_hash(hashlib.sha256(payload).hexdigest(), 'fast', False,
                                         texture_compression=source_enabled)
    result = Path(server.OUTPUT_DIR) / 'previous.zip'
    result.write_bytes(b'previous output')
    server.job_store.create(_job('previous', status='completed', result_zip=str(result),
                                input_hash=source_hash, texture_compression=source_enabled))
    response = upload(client, payload, str(int(not source_enabled)))
    job = server.job_store.get(response.json['job_id'])
    assert job['status'] == 'queued' and job['source_job_id'] is None
    assert job['texture_compression'] is (not source_enabled)
    assert len(submissions) == 1


@pytest.mark.parametrize('enabled', [False, True])
def test_web_reuses_same_texture_selection_and_keeps_saved_choice(api, enabled):
    server, client, submissions = api
    payload = scan_zip()
    source_hash = server._make_input_hash(hashlib.sha256(payload).hexdigest(), 'fast', False,
                                         texture_compression=enabled)
    result = Path(server.OUTPUT_DIR) / 'previous.zip'
    result.write_bytes(b'previous output')
    server.job_store.create(_job('previous', status='completed', result_zip=str(result),
                                input_hash=source_hash, texture_compression=enabled))
    response = upload(client, payload, str(int(enabled)))
    job_id = response.json['job_id']
    job = server.job_store.get(job_id)
    assert job['status'] == 'completed' and job['source_job_id'] == 'previous'
    assert client.get('/api/status/' + job_id).json['texture_compression'] is enabled
    assert not submissions


@pytest.mark.parametrize('value, expected', [(None, False), ('1', True)])
def test_worker_forwards_reloaded_texture_selection_to_pipeline(api, monkeypatch, tmp_path, value, expected):
    server, client, submissions = api
    response = upload(client, scan_zip(), value)
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    monkeypatch.setattr(server, 'job_store', server.JobStore(server.job_store.db_path))
    server.jobs.clear()
    server._job_cache_read_at.clear()
    server.run_pipeline(*submissions[0])
    assert server.job_store.get(response.json['job_id'])['status'] == 'completed'
    assert calls['options']['texture_compression'] is expected


def test_mobile_omission_persists_and_forwards_default_false(api, monkeypatch, tmp_path):
    server, client, submissions = api
    # Exercise worker option forwarding with a frame eligible for V1 quality selection.
    pixels = np.random.default_rng(42).integers(24, 232, (24, 32), dtype=np.uint8)
    encoded, image = cv2.imencode('.png', pixels)
    assert encoded
    response = submit(client, scan_zip(extra={'images/f.png': image.tobytes()}), uv_unwrap='0')
    assert response.status_code == 202
    assert server.job_store.get(response.json['job_id'])['texture_compression'] is False
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    server.run_pipeline(*submissions[0])
    assert server.job_store.get(response.json['job_id'])['status'] == 'completed'
    assert calls['options']['texture_compression'] is False


def test_web_ui_exposes_default_off_texture_compression_choice():
    source = (Path(__file__).resolve().parents[1] / 'web_service/static/index.html').read_text()
    checkbox = re.search(r'<input\b[^>]*\bid="texture-compression"[^>]*>', source)
    assert checkbox, 'Web upload needs its explicit texture compression checkbox'
    assert 'type="checkbox"' in checkbox.group(0)
    assert not re.search(r'\bchecked\b', checkbox.group(0))
    assert '压缩纹理为 WebP（需要查看器支持）' in source
    assert re.search(r"append\(['\"]texture_compression['\"]", source)
