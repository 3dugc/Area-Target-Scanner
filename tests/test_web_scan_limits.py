"""Web jobs accept a billion raw frame pixels before enforcing their limit."""
import hashlib
import io
import json
from pathlib import Path
import zipfile

import pytest

from tests.test_mobile_api import api  # noqa: F401
from tests.test_mobile_scan_preparation import many_frame_zip, install_worker_boundary_fakes


def web_scan_zip(*, legacy=False, count=100, size=(1920, 1440)):
    payload = many_frame_zip(count=count, size=size)
    result = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(payload)) as source, zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as output:
        manifest = json.loads(source.read('manifest.json'))
        for entry in source.infolist():
            if legacy and entry.filename == 'manifest.json':
                output.writestr('poses.json', json.dumps({'frames': manifest['frames']}))
                output.writestr('intrinsics.json', json.dumps(manifest['frames'][0]['intrinsics']))
            else:
                output.writestr(entry.filename, source.read(entry))
        output.writestr('model.mtl', 'newmtl surface\nmap_Kd texture.jpg\n')
        output.writestr('texture.jpg', source.read('images/0.jpg'))
    return result.getvalue()


def upload_web(client, payload, *, uv_unwrap=False, profile='fast'):
    return client.post('/api/upload', data={'file': (io.BytesIO(payload), 'scan.zip'),
        'profile': profile, 'uv_unwrap': str(int(uv_unwrap))})


@pytest.mark.parametrize('profile', ['fast', 'quality'])
@pytest.mark.parametrize('legacy', [False, True])
@pytest.mark.parametrize('uv_unwrap', [False, True])
def test_web_accepts_100_full_resolution_frames_without_preparation(api, monkeypatch, tmp_path,
                                                                  profile, legacy, uv_unwrap):
    server, client, submissions = api
    payload = web_scan_zip(legacy=legacy)
    response = upload_web(client, payload, profile=profile, uv_unwrap=uv_unwrap)
    assert response.status_code == 200, response.json
    job_id = response.json['job_id']
    assert server.job_store.get(job_id)['token_hash'] is None
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    import processing_pipeline.scan_preparation as preparation
    monkeypatch.setattr(preparation, 'prepare_scan', lambda *a, **kw: pytest.fail('Web source was prepared'))
    monkeypatch.setattr(server, '_run_uv_unwrap_job', lambda job_id, root, **kw: calls.update(uvRoot=root))
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(job_id)
    assert job['status'] == 'completed', job.get('error')
    assert calls['options']['mobile_feature_limits'] is False
    assert len(calls['images']) == 100
    raw = Path(server.UPLOAD_DIR) / job_id / 'extracted'
    assert Path(calls['root']) == raw
    assert Path(submissions[0][1]).read_bytes() == payload
    if not legacy:
        assert all((frame['width'], frame['height']) == (1920, 1440) for frame in calls['images'])
    with zipfile.ZipFile(io.BytesIO(payload)) as source:
        for entry in source.infolist():
            assert hashlib.sha256((raw / entry.filename).read_bytes()).digest() == hashlib.sha256(source.read(entry)).digest()
    if uv_unwrap:
        assert calls['uvRoot'] == calls['root']
    with zipfile.ZipFile(job['result_zip']) as bundle:
        manifest = json.loads(bundle.read('manifest.json'))
    assert manifest['keyframeCount'] == 100
    assert 'scanPreparation' not in manifest


@pytest.mark.parametrize('count,accepted', [(160, True), (161, False)])
def test_web_enforces_actual_billion_pixel_boundary(api, monkeypatch, tmp_path, count, accepted):
    server, client, submissions = api
    payload = web_scan_zip(count=count, size=(2500, 2500))
    response = upload_web(client, payload)
    assert response.status_code == 200
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(response.json['job_id'])
    if accepted:
        assert count * 2500 * 2500 == 1_000_000_000
        assert job['status'] == 'completed', job.get('error')
        assert len(calls['images']) == count
    else:
        assert job['status'] == 'failed'
        assert 'Scan images exceed the total pixel limit' in job['error']
        assert not calls


def test_web_billion_pixel_budget_keeps_single_image_guard(api, monkeypatch, tmp_path):
    server, client, submissions = api
    response = upload_web(client, web_scan_zip())
    assert response.status_code == 200
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    import processing_pipeline.scan_security as security
    monkeypatch.setattr(security, 'MAX_IMAGE_PIXELS', 2_000_000)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(response.json['job_id'])
    assert job['status'] == 'failed'
    assert 'image exceeds the pixel limit' in job['error']
    assert not calls
