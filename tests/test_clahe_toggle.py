"""Optional map preprocessing: real tiny images and durable submission contracts."""
import hashlib
import io
import json
import sqlite3
import uuid
from html.parser import HTMLParser
from pathlib import Path

import cv2
import numpy as np
import open3d as o3d
import pytest
import trimesh
from werkzeug.datastructures import MultiDict

from processing_pipeline.feature_extraction import build_feature_database
from processing_pipeline.models import FeatureDatabase
from processing_pipeline.optimized_pipeline import OptimizedPipeline, FEATURE_PROFILE_OPTIONS
from tests.test_mobile_api import api, headers, scan_zip, submit, JOB_ID
from tests.test_web_job_store import _job, _isolate_app_store


@pytest.fixture
def tiny_image(tmp_path):
    gray = np.random.default_rng(17).integers(60, 150, (240, 320), dtype=np.uint8)
    path = tmp_path / 'source.png'
    assert cv2.imwrite(str(path), gray)
    mesh = o3d.geometry.TriangleMesh.create_box(100, 100, .1).translate((-50, -50, -3))
    return path, gray, mesh


def extract(tiny_image, **options):
    path, _, mesh = tiny_image
    return build_feature_database([{'path': str(path), 'pose': np.eye(4)}], mesh,
        orb_nfeatures=100, bow_k=1, use_minibatch_kmeans=True,
        kmeans_n_init=1, kmeans_max_iter=1, **options)


def test_real_detectors_share_one_fixed_clahe_gray_without_writing_source(tiny_image, monkeypatch):
    path, gray, _ = tiny_image
    source_bytes = path.read_bytes()
    expected = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    calls, images = [], {}
    clahe_factory, orb_factory = cv2.createCLAHE, cv2.ORB_create
    akaze_module = cv2 if hasattr(cv2, 'AKAZE_create') else cv2.xfeatures2d
    akaze_factory = akaze_module.AKAZE_create

    def clahe(**kwargs):
        calls.append(kwargs)
        return clahe_factory(**kwargs)

    class Detector:
        def __init__(self, name, actual):
            self.name, self.actual = name, actual

        def detectAndCompute(self, image, mask):
            images[self.name] = image
            return self.actual.detectAndCompute(image, mask)

    monkeypatch.setattr(cv2, 'createCLAHE', clahe)
    monkeypatch.setattr(cv2, 'ORB_create', lambda **kw: Detector('orb', orb_factory(**kw)))
    monkeypatch.setattr(akaze_module, 'AKAZE_create', lambda **kw: Detector('akaze', akaze_factory(**kw)))
    database = extract(tiny_image, map_clahe=True)
    assert len(database.keyframes) == 1 and len(database.keyframes[0].akaze_descriptors) > 0
    assert calls == [{'clipLimit': 2.0, 'tileGridSize': (8, 8)}]
    assert images['orb'] is images['akaze']
    np.testing.assert_array_equal(images['orb'], expected)
    assert path.read_bytes() == source_bytes


def test_default_and_false_keep_original_gray_and_feature_bytes(tiny_image, monkeypatch):
    monkeypatch.setattr(cv2, 'createCLAHE', lambda **_: pytest.fail('off must not apply CLAHE'))
    default, explicit = extract(tiny_image), extract(tiny_image, map_clahe=False)
    assert len(default.keyframes) == len(explicit.keyframes) == 1
    for attribute in ('descriptors', 'akaze_descriptors', 'keypoints', 'points_3d'):
        np.testing.assert_array_equal(getattr(default.keyframes[0], attribute), getattr(explicit.keyframes[0], attribute))


@pytest.mark.parametrize('invalid', [0, 1, '0', '1', None, np.bool_(True)])
def test_python_entry_points_require_actual_bool(invalid):
    with pytest.raises(ValueError, match='map_clahe.*bool'):
        OptimizedPipeline(map_clahe=invalid)
    with pytest.raises(ValueError, match='map_clahe.*bool'):
        build_feature_database([], o3d.geometry.TriangleMesh(), map_clahe=invalid)


@pytest.mark.parametrize('profile', ['quality', 'fast'])
@pytest.mark.parametrize('enabled', [False, True])
def test_pipeline_forwards_toggle_without_changing_profile_or_mobile_budget(monkeypatch, profile, enabled):
    import processing_pipeline.feature_extraction as extractor
    pipeline = OptimizedPipeline(processing_profile=profile, mobile_preparation_policy='mobile-scan-preparation-v2',
                                 mobile_preparation_capacity=500, map_clahe=enabled)
    captured = {}
    monkeypatch.setattr(pipeline, '_trimesh_to_o3d', lambda mesh: mesh)
    monkeypatch.setattr(extractor, 'build_feature_database', lambda *args, **kw: captured.update(kw))
    pipeline.build_feature_database(object(), [{'id': 1}])
    assert captured.get('map_clahe', False) is enabled
    expected = dict(FEATURE_PROFILE_OPTIONS[profile])
    expected.update(max_keyframes=None, keyframe_selection='even', mobile_feature_budget=profile)
    if expected['extract_akaze']:
        expected['max_akaze_features'] = 500
    if enabled:
        expected['map_clahe'] = True
    assert captured == expected


@pytest.mark.parametrize('enabled,recipe', [(False, {'mode': 'none'}),
    (True, {'mode': 'clahe', 'clipLimit': 2.0, 'tileGridSize': [8, 8]})])
def test_bundle_records_preprocessing_without_changing_producer_or_database(tmp_path, enabled, recipe):
    mesh = trimesh.creation.box()
    glb = tmp_path / 'source.glb'
    mesh.export(glb)
    out = tmp_path / 'bundle'
    OptimizedPipeline(map_clahe=enabled).export_asset_bundle(str(glb), mesh, FeatureDatabase(keyframes=[]), str(out))
    manifest = json.loads((out / 'manifest.json').read_text())
    assert manifest['mapPreprocessing'] == recipe
    assert manifest['producer'] == {'opencvVersion': cv2.__version__}
    with sqlite3.connect(out / 'features.db') as db:
        assert 'map_clahe' not in [row[1] for row in db.execute('PRAGMA table_info(keyframes)')]


def test_history_migrates_to_false_and_new_choice_survives_restart(tmp_path):
    import web_service.app as server
    path = tmp_path / 'old.sqlite'
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, status TEXT NOT NULL, step TEXT, progress INTEGER NOT NULL DEFAULT 0, error TEXT, result_zip TEXT, uv_unwrap INTEGER NOT NULL DEFAULT 0, profile TEXT NOT NULL DEFAULT "fast", input_hash TEXT, source_job_id TEXT, created_at TEXT NOT NULL, finished_at TEXT)')
        db.execute('INSERT INTO jobs(id,status,created_at) VALUES("old","completed","2026-10-08T00:00:00+00:00")')
    store = server.JobStore(str(path))
    assert store.get('old')['map_clahe'] is False
    assert store.create(_job('default'))['map_clahe'] is False
    assert store.create(_job('on', map_clahe=True))['map_clahe'] is True
    assert server.JobStore(str(path)).get('on')['map_clahe'] is True
    with sqlite3.connect(path) as db:
        info = {row[1]: row for row in db.execute('PRAGMA table_info(jobs)')}
        assert info['map_clahe'][3:5] == (1, '0')


@pytest.mark.parametrize('policy', ['mobile-scan-preparation-v1', 'mobile-scan-preparation-v2'])
def test_requirements_reports_top_level_capability(api, policy):
    _, client, _ = api
    response = client.get('/api/v1/processing-requirements?policy=' + policy)
    assert response.status_code == 200 and response.json['map_clahe_supported'] is True


def test_api_freezes_choice_and_separates_idempotency_preserving_old_off_fingerprint(api):
    server, client, submissions = api
    payload = scan_zip()
    response = submit(client, payload)
    assert response.status_code == 202 and response.json['map_clahe'] is False
    old_fingerprint = hashlib.sha256(f'{hashlib.sha256(payload).hexdigest()}:fast:1'.encode()).hexdigest()
    assert server.job_store.get(JOB_ID)['input_hash'] == old_fingerprint
    assert submit(client, payload, map_clahe='0').status_code == 200
    assert submit(client, payload, map_clahe='1').status_code == 409
    enabled_id = str(uuid.uuid4())
    response = submit(client, payload, job_id=enabled_id, map_clahe='1')
    assert response.status_code == 202 and response.json['map_clahe'] is True
    enabled = server.job_store.get(enabled_id)
    assert enabled['map_clahe'] is True and enabled['input_hash'] != old_fingerprint
    assert submit(client, payload, job_id=enabled_id, map_clahe='1').status_code == 200
    assert submit(client, payload, job_id=enabled_id).status_code == 409
    assert len(submissions) == 2 and len(submissions[0]) == 4
    assert submissions[1][2:] == (True, 'fast', True)
    restored = server.JobStore(server.job_store.db_path)
    assert restored.get(enabled_id)['map_clahe'] is True


@pytest.mark.parametrize('route', ['/api/v1/jobs', '/api/upload'])
@pytest.mark.parametrize('values', [[''], ['true'], ['false'], ['2'], [' 1'], ['0', '1']])
def test_form_is_exact_single_zero_or_one_before_creating_jobs(api, route, values):
    server, client, submissions = api
    form = MultiDict([('file', (io.BytesIO(scan_zip()), 'scan.zip')), ('profile', 'fast'), ('uv_unwrap', '1')])
    for value in values:
        form.add('map_clahe', value)
    response = client.post(route, headers=headers(), data=form)
    assert response.status_code == 400
    assert server.job_store.list_all() == [] and submissions == []
    assert list(Path(server.UPLOAD_DIR).iterdir()) == []


@pytest.mark.parametrize('texture_compression', [False, True])
def test_web_cache_two_states_and_job_echo(api, tmp_path, texture_compression):
    server, client, submissions = api
    payload = scan_zip()
    zip_hash = hashlib.sha256(payload).hexdigest()
    from processing_pipeline.scan_preparation import POLICY_V2
    from processing_pipeline.keyframe_quality import SELECTION_VERSION
    old_payload = f'{zip_hash}:fast:0:{int(texture_compression)}:{server.PIPELINE_CACHE_VERSION}:{cv2.__version__}:{POLICY_V2}:{SELECTION_VERSION}'
    old_hash = hashlib.sha256(old_payload.encode()).hexdigest()
    assert server._make_input_hash(zip_hash, 'fast', False, texture_compression=texture_compression, map_clahe=False) == old_hash
    assert server._make_input_hash(zip_hash, 'fast', False, texture_compression=texture_compression, map_clahe=True) != old_hash
    result = tmp_path / 'baseline.zip'
    result.write_bytes(b'old completed bundle without mapPreprocessing')
    server._create_job(_job('old-off', status='completed', input_hash=old_hash, result_zip=str(result), texture_compression=texture_compression))
    def upload(value=None):
        data = {'file': (io.BytesIO(payload), 'scan.zip'), 'uv_unwrap': '0', 'texture_compression': str(int(texture_compression))}
        if value is not None:
            data['map_clahe'] = value
        response = client.post('/api/upload', data=data)
        assert response.status_code == 200
        job = client.get('/api/status/' + response.json['job_id']).json
        return job
    off = upload()
    assert off['status'] == 'completed' and off['source_job_id'] == 'old-off' and off['map_clahe'] is False
    enabled = upload('1')
    assert enabled['status'] == 'queued' and enabled['source_job_id'] is None and enabled['map_clahe'] is True
    assert enabled['texture_compression'] is texture_compression
    assert submissions[-1][2:] == (False, 'fast', True)
    server._update_job(enabled['id'], status='completed', result_zip=str(result))
    enabled_cached = upload('1')
    assert enabled_cached['source_job_id'] == enabled['id'] and enabled_cached['map_clahe'] is True
    final_off = upload('0')
    assert final_off['source_job_id'] in {'old-off', off['id']}
    assert final_off['map_clahe'] is False and final_off['input_hash'] == old_hash
    assert len(submissions) == 1


def test_executor_forwards_frozen_on_choice(monkeypatch, tmp_path):
    server, *_ = _isolate_app_store(monkeypatch, tmp_path)
    calls = []
    class Executor:
        def submit(self, function, *args):
            calls.append((function, args))
    monkeypatch.setattr(server, 'pipeline_executor', Executor())
    server._submit_pipeline_job('off', 'upload.zip', False, 'fast')
    server._submit_pipeline_job('on', 'upload.zip', True, 'quality', True)
    assert calls == [(server.run_pipeline, ('off', 'upload.zip', False, 'fast')),
                     (server.run_pipeline, ('on', 'upload.zip', True, 'quality', True))]


@pytest.mark.parametrize('enabled', [False, True])
def test_worker_consumes_frozen_choice_before_optimizer_boundary(api, tmp_path, monkeypatch, enabled):
    server, _, _ = api
    job_id = 'worker-' + str(enabled)
    parent = Path(server.UPLOAD_DIR) / job_id
    parent.mkdir()
    zip_path = parent / 'upload.zip'
    zip_path.write_bytes(scan_zip())
    server._create_job(_job(job_id, map_clahe=enabled))
    captured = {}
    class Pipeline:
        def __init__(self, **kwargs):
            captured.update(kwargs)
        def validate_input(self, _):
            raise ValueError('intentional test stop before optimizer/network')
    import processing_pipeline.optimized_pipeline as module
    monkeypatch.setattr(module, 'OptimizedPipeline', Pipeline)
    server.run_pipeline(job_id, str(zip_path), False, 'fast', enabled)
    assert captured.get('map_clahe', False) is enabled
    assert captured['processing_profile'] == 'fast' and captured['mobile_feature_limits'] is False
    assert server.job_store.get(job_id)['status'] == 'failed'


def test_web_default_off_and_openapi_contract():
    root = Path(__file__).parents[1] / 'web_service'
    class Inputs(HTMLParser):
        def __init__(self):
            super().__init__(); self.inputs = {}
        def handle_starttag(self, tag, attrs):
            if tag == 'input':
                item = dict(attrs)
                self.inputs[item.get('id')] = item
    html = (root / 'static/index.html').read_text()
    parser = Inputs(); parser.feed(html)
    assert parser.inputs['mapClaheCheck']['type'] == 'checkbox'
    assert 'checked' not in parser.inputs['mapClaheCheck']
    assert "if(mapClahe) fd.append('map_clahe', '1')" in html
    assert '更改此选项需要重新建图' in html
    assert 'texture-compression' in html and '<!-- build-version -->' in html
    spec = json.loads((root / 'openapi.json').read_text())
    field = spec['paths']['/api/v1/jobs']['post']['requestBody']['content']['multipart/form-data']['schema']['properties']['map_clahe']
    assert field['enum'] == ['0', '1'] and field['default'] == '0'
    assert spec['components']['schemas']['Job']['properties']['map_clahe']['type'] == 'boolean'
    assert spec['components']['schemas']['ProcessingRequirements']['properties']['map_clahe_supported']['type'] == 'boolean'


@pytest.mark.parametrize('enabled', [False, True])
@pytest.mark.parametrize('texture_compression', [False, True])
def test_worker_reload_uses_saved_clahe_and_preserves_texture_choice(api, monkeypatch, tmp_path, enabled, texture_compression):
    from tests.test_mobile_scan_preparation import install_worker_boundary_fakes
    server, client, submissions = api
    response = client.post('/api/upload', data={'file': (io.BytesIO(scan_zip()), 'scan.zip'),
        'uv_unwrap': '0', 'map_clahe': str(int(enabled)), 'texture_compression': str(int(texture_compression))})
    assert response.status_code == 200
    job_id = response.json['job_id']
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    monkeypatch.setattr(server, 'job_store', server.JobStore(server.job_store.db_path))
    server.jobs.clear(); server._job_cache_read_at.clear()
    # Omit the new positional argument to emulate an existing resumed worker.
    server.run_pipeline(*submissions[0][:4])
    assert server.job_store.get(job_id)['status'] == 'completed'
    assert calls['options'].get('map_clahe', False) is enabled
    assert calls['options']['texture_compression'] is texture_compression


def test_requirements_capability_does_not_change_v2_budget_or_default_profile(api):
    from processing_pipeline.scan_preparation import processing_requirements
    server, client, _ = api
    for policy in ['mobile-scan-preparation-v1', 'mobile-scan-preparation-v2']:
        existing = processing_requirements(maximum_request_bytes=server.app.config['MAX_CONTENT_LENGTH'], policy=policy)
        actual = client.get('/api/v1/processing-requirements?policy=' + policy).json
        assert actual.pop('map_clahe_supported') is True
        assert actual == existing
