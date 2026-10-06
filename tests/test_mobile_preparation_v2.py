"""Negotiation and a real preparation/worker boundary for coverage-preserving v2."""
import io
import json
import zipfile

import pytest

from processing_pipeline.scan_preparation import POLICY_V2, upload_selection_digest
from tests.test_mobile_api import api, submit, headers  # noqa: F401
from tests.test_mobile_scan_preparation import many_frame_zip, install_worker_boundary_fakes


def v2_zip(count, *, capacity=100, size=(80, 60), modify=None):
    payload = many_frame_zip(count=count, size=size)
    result = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(payload)) as source, zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as output:
        for entry in source.infolist():
            data = source.read(entry)
            if entry.filename == 'manifest.json':
                manifest = json.loads(data)
                metadata = {'schemaVersion': 1, 'policy': POLICY_V2, 'policyVersion': 2,
                    'profile': 'fast', 'preparedBy': 'client', 'originalFrameCount': count,
                    'selectedFrameCount': count, 'selectedIndices': list(range(count)),
                    'processedPixelCount': count * size[0] * size[1], 'resizedFrameCount': 0,
                    'maximumOutputLongEdge': max(size), 'scaleDigest': 'a' * 64,
                    'receivedFrameCount': count, 'capacityTier': capacity, 'selectionVersion': 'upload-all-v2',
                    'selectionDigest': upload_selection_digest(capacity, list(range(count)))}
                if modify:
                    modify(metadata)
                manifest['clientPreparation'] = metadata
                data = json.dumps(manifest).encode()
            output.writestr(entry.filename, data)
    return result.getvalue()


def test_v2_public_negotiation_rejects_unknown_policy(api, monkeypatch):
    _, client, _ = api
    monkeypatch.delenv('AREA_TARGET_PREPARATION_TIER', raising=False)
    response = client.get('/api/v1/processing-requirements?policy=' + POLICY_V2)
    assert response.status_code == 200
    assert response.json['policyVersion'] == 2 and response.json['capacityTier'] == 100
    response = client.get('/api/v1/processing-requirements?policy=unknown')
    assert response.status_code == 400
    assert response.json['error']['code'] == 'unsupported_preparation_policy'


@pytest.mark.parametrize('count,size', [(100, (80, 60)), (500, (80, 60)), (500, (1024, 1024))])
def test_v2_worker_preserves_all_distinct_frames_and_policy(api, monkeypatch, tmp_path, count, size):
    server, client, submissions = api
    monkeypatch.setenv('AREA_TARGET_PREPARATION_TIER', str(count))
    payload = v2_zip(count, capacity=count, size=size)
    response = submit(client, payload)
    assert response.status_code == 202, response.json
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    def unwrap(job_id, root, **kwargs):
        from pathlib import Path
        from PIL import Image
        assert len(json.loads((Path(root) / 'manifest.json').read_text())['frames']) == count
        (Path(root) / 'model.mtl').write_text('newmtl surface\nmap_Kd texture.jpg\n')
        Image.new('RGB', (16, 16), 'red').save(Path(root) / 'texture.jpg')
    monkeypatch.setattr(server, '_run_uv_unwrap_job', unwrap)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(submissions[0][0])
    assert job['status'] == 'completed', job.get('error')
    assert len(calls['images']) == count
    assert calls['options']['mobile_preparation_policy'] == POLICY_V2
    assert calls['options']['mobile_preparation_capacity'] == count
    with zipfile.ZipFile(job['result_zip']) as bundle:
        result = json.loads(bundle.read('manifest.json'))
    assert result['scanPreparation']['selectedFrameCount'] == count
    assert result['scanPreparation']['processedPixelCount'] == count * size[0] * size[1]
    assert result['clientPreparation']['selectionDigest'] == upload_selection_digest(count, list(range(count)))
    from pathlib import Path
    assert Path(submissions[0][1]).read_bytes() == payload


def test_v2_over_capacity_reports_actionable_error_without_second_sampling(api, monkeypatch, tmp_path):
    server, client, submissions = api
    monkeypatch.delenv('AREA_TARGET_PREPARATION_TIER', raising=False)
    assert submit(client, v2_zip(101)).status_code == 202
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(submissions[0][0])
    assert job['status'] == 'failed' and job['error_code'] == 'coverage_budget_exceeded'
    response = client.get('/api/v1/jobs/' + job['id'], headers=headers())
    assert response.json['error']['code'] == 'coverage_budget_exceeded'
    assert response.json['error']['retryable'] is False
    assert response.json['error']['details']['receivedFrameCount'] == 101
    assert response.json['error']['details']['duplicateFrameCount'] == 0
    assert response.json['error']['details']['selectedFrameCount'] == 101
    assert response.json['error']['details']['maximumTotalPixels'] == 200_000_000
    assert not calls


def test_v2_preflight_rejects_tampered_digest_and_disabled_tier(api, monkeypatch):
    _, client, submissions = api
    monkeypatch.delenv('AREA_TARGET_PREPARATION_TIER', raising=False)
    response = submit(client, v2_zip(5, modify=lambda m: m.update(selectionDigest='b' * 64)))
    assert response.status_code == 400
    response = submit(client, v2_zip(5, capacity=500))
    assert response.status_code == 400 and response.json['error']['code'] == 'coverage_budget_exceeded'
    assert not submissions


@pytest.mark.parametrize('capacity', [100.0, True])
def test_v2_preflight_rejects_non_integer_capacity(api, capacity):
    _, client, submissions = api
    response = submit(client, v2_zip(5, capacity=capacity))
    assert response.status_code == 400
    assert not submissions


def test_v2_protected_originals_pass_preflight_and_survive_real_worker_preparation(api, monkeypatch, tmp_path):
    server, client, submissions = api
    extension = {'version': 'critical-frame-protection-v1', 'riskVersion': 'gray-quality-risk-v1',
                 'protectedIndices': [0, 1], 'candidateFrameCount': 2}
    payload = v2_zip(2, size=(1920, 1440), modify=lambda m: m.update(criticalFrameProtection=extension))
    response = submit(client, payload)
    assert response.status_code == 202, response.json
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    def unwrap(job_id, root, **kwargs):
        from pathlib import Path
        from PIL import Image
        frames = json.loads((Path(root) / 'manifest.json').read_text())['frames']
        assert [f['image'] for f in frames] == [{'width': 1920, 'height': 1440}] * 2
        (Path(root) / 'model.mtl').write_text('newmtl surface\nmap_Kd texture.jpg\n')
        Image.new('RGB', (16, 16), 'red').save(Path(root) / 'texture.jpg')
    monkeypatch.setattr(server, '_run_uv_unwrap_job', unwrap)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(submissions[0][0])
    assert job['status'] == 'completed', job.get('error')
    with zipfile.ZipFile(job['result_zip']) as bundle:
        manifest = json.loads(bundle.read('manifest.json'))
    assert manifest['clientPreparation']['criticalFrameProtection'] == extension
    assert manifest['scanPreparation']['criticalFrameProtection']['protectedIndices'] == [0, 1]


@pytest.mark.parametrize('indices', [[], [1], [0, 0], [True]])
def test_v2_preflight_cannot_claim_high_resolution_for_another_frame(api, indices):
    _, client, submissions = api
    extension = {'version': 'critical-frame-protection-v1', 'riskVersion': 'gray-quality-risk-v1',
                 'protectedIndices': indices, 'candidateFrameCount': 1}
    response = submit(client, v2_zip(1, size=(1920, 1440),
                                   modify=lambda m: m.update(criticalFrameProtection=extension)))
    assert response.status_code == 400
    assert not submissions
