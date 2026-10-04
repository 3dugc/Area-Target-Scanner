"""Mobile preparation uses actual image resources and preserves raw scan identity."""
import io
import json
import zipfile

import pytest

from PIL import Image

from tests.test_mobile_api import api, submit  # noqa: F401


@pytest.fixture
def api_boundary(request):
    return request.getfixturevalue("api")


def many_frame_zip(count=73, size=(1920, 1440)):
    image = io.BytesIO()
    Image.new('RGB', size, 'gray').save(image, format='JPEG')
    width, height = size
    frames = [{'index': index, 'timestamp': index * .5, 'imageFile': f'images/{index}.jpg',
               'transform': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, index * .1, 0, 0, 1],
               'imageOrientation': 'landscapeRight', 'image': {'width': width, 'height': height},
               'intrinsics': {'fx': width * .8, 'fy': height * .8, 'cx': width / 2, 'cy': height / 2}}
              for index in range(count)]
    manifest = {'schemaVersion': 1, 'coordinateSystem': 'arkit-world',
                'matrixLayout': 'arkit-column-major', 'units': 'meters', 'frames': frames}
    result = io.BytesIO()
    with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('model.obj', 'v 0 0 -1\nv 1 0 -1\nv 0 1 -1\nf 1 2 3\n')
        archive.writestr('manifest.json', json.dumps(manifest))
        for frame in frames:
            archive.writestr(frame['imageFile'], image.getvalue())
    return result.getvalue()


def test_mobile_admits_73_raw_frames_over_200m_pixels_without_altering_upload(api_boundary):
    server, client, submissions = api_boundary
    payload = many_frame_zip()
    response = submit(client, payload)
    assert response.status_code == 202, response.json
    assert len(submissions) == 1
    from pathlib import Path
    assert Path(submissions[0][1]).read_bytes() == payload


def test_processing_requirements_are_public_and_bounded(api_boundary):
    _, client, _ = api_boundary
    response = client.get('/api/v1/processing-requirements')
    assert response.status_code == 200
    requirements = response.json
    assert requirements['schemaVersion'] == requirements['policyVersion'] == 1
    assert requirements['policy'] == 'mobile-scan-preparation-v1'
    for profile in ('fast', 'quality'):
        assert requirements['profiles'][profile] == {
            'maxFrames': 80, 'maximumLongEdge': 1600, 'maximumTotalPixels': 200_000_000}
    assert requirements['safety'] == {
        'maximumRequestBytes': 536_870_912, 'maximumExpandedBytes': 524_288_000,
        'maximumArchiveEntries': 10_000, 'maximumSourceFrameCount': 10_000,
        'maximumImagePixels': 32_000_000, 'maximumImageDimension': 8192,
        'maximumMetadataBytes': 8_388_608}


def install_worker_boundary_fakes(monkeypatch, tmp_path, *, fail_optimization=False):
    """Keep preparation/files/packaging real; fake external optimizer and feature work."""
    import processing_pipeline.optimized_pipeline as optimized
    real_validate = optimized.OptimizedPipeline.validate_input
    calls = {}

    class Pipeline:
        def __init__(self, **options):
            calls['options'] = options
        def validate_input(self, root):
            calls['root'] = root
            return real_validate(self, root)
        def optimize_model(self, scan, directory):
            if fail_optimization:
                raise RuntimeError('synthetic optimizer unavailable')
            import trimesh
            from pathlib import Path
            glb = Path(directory) / 'optimized.glb'
            trimesh.creation.box().export(glb)
            return str(glb)
        def build_feature_database(self, mesh, images, intrinsics):
            calls['images'] = images
            return object()
        def export_asset_bundle(self, glb, mesh, features, directory):
            from pathlib import Path
            import shutil
            shutil.copyfile(glb, Path(directory) / 'optimized.glb')
            (Path(directory) / 'manifest.json').write_text(json.dumps({'version': '1.0', 'keyframeCount': len(calls['images'])}))
    monkeypatch.setattr(optimized, 'OptimizedPipeline', Pipeline)
    return calls


def test_mobile_worker_prepares_before_uv_and_exports_actual_policy_without_mutating_raw(api_boundary, monkeypatch, tmp_path):
    server, client, submissions = api_boundary
    payload = many_frame_zip(count=100)
    assert submit(client, payload).status_code == 202
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path)
    from pathlib import Path
    def uv(job_id, scan_root, **options):
        root = Path(scan_root)
        calls['uvRoot'] = root
        manifest = json.loads((root / 'manifest.json').read_text())
        assert len(manifest['frames']) == 80
        assert manifest['frames'][0]['image'] == {'width': 1600, 'height': 1200}
        (root / 'model.obj').write_text('v 0 0 -2\nv 1 0 -2\nv 0 1 -2\nf 1 2 3\n')
        (root / 'model.mtl').write_text('newmtl surface\nmap_Kd texture.jpg\n')
        Image.new('RGB', (16, 16), 'red').save(root / 'texture.jpg')
    monkeypatch.setattr(server, '_run_uv_unwrap_job', uv)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(submissions[0][0])
    assert job['status'] == 'completed', job.get('error')
    assert calls['options']['mobile_feature_limits'] is True
    assert len(calls['images']) == 80
    raw = Path(server.UPLOAD_DIR) / job['id'] / 'extracted'
    assert json.loads((raw / 'manifest.json').read_text())['frames'][-1]['index'] == 99
    assert (raw / 'model.obj').read_text().startswith('v 0 0 -1')
    assert not (raw / 'poses.json').exists() and not (raw / 'texture.jpg').exists()
    assert not calls['uvRoot'].exists()
    with zipfile.ZipFile(job['result_zip']) as bundle:
        manifest = json.loads(bundle.read('manifest.json'))
    preparation = manifest['scanPreparation']
    assert preparation['originalFrameCount'] == 100 and preparation['selectedFrameCount'] == 80
    assert preparation['selectedIndices'][0] == 0 and preparation['selectedIndices'][-1] == 99
    assert preparation['processedPixelCount'] == 153_600_000
    assert preparation['maximumOutputLongEdge'] == 1600
    assert preparation['preparedBy'] == 'server'


def test_worker_failure_cleans_derivative_but_retains_original_upload(api_boundary, monkeypatch, tmp_path):
    server, client, submissions = api_boundary
    payload = many_frame_zip(count=1, size=(32, 24))
    assert submit(client, payload).status_code == 202
    calls = install_worker_boundary_fakes(monkeypatch, tmp_path, fail_optimization=True)
    # No texture is needed until validation, so synthesize only the external UV boundary.
    from pathlib import Path
    def uv(job, root, **kwargs):
        (Path(root) / 'model.mtl').write_text('newmtl surface\nmap_Kd texture.jpg\n')
        Image.new('RGB', (16, 16), 'gray').save(Path(root) / 'texture.jpg')
    monkeypatch.setattr(server, '_run_uv_unwrap_job', uv)
    server.run_pipeline(*submissions[0])
    job = server.job_store.get(submissions[0][0])
    assert job['status'] == 'failed'
    assert 'root' in calls
    assert not Path(calls['root']).exists()
    assert Path(submissions[0][1]).read_bytes() == payload
    assert (Path(server.UPLOAD_DIR) / job['id'] / 'extracted' / 'model.obj').is_file()


def with_client_metadata(payload, **changes):
    original = io.BytesIO(payload)
    result = io.BytesIO()
    with zipfile.ZipFile(original) as source, zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as destination:
        for info in source.infolist():
            data = source.read(info)
            if info.filename == 'manifest.json':
                manifest = json.loads(data)
                manifest['clientPreparation'] = {'schemaVersion': 1, 'policy': 'mobile-scan-preparation-v1',
                    'policyVersion': 1, 'profile': 'fast', 'preparedBy': 'client', 'originalFrameCount': 120,
                    'selectedFrameCount': 3, 'selectedIndices': [0, 59, 119], 'processedPixelCount': 14400,
                    'resizedFrameCount': 3, 'maximumOutputLongEdge': 80, 'scaleDigest': 'a' * 64, **changes}
                data = json.dumps(manifest).encode()
            destination.writestr(info.filename, data)
    return result.getvalue()


def test_client_preparation_admission_validates_actual_dimensions_pixels_and_bounded_provenance(api_boundary):
    _, client, submissions = api_boundary
    import uuid
    payload = many_frame_zip(count=3, size=(80, 60))
    assert submit(client, with_client_metadata(payload)).status_code == 202
    for changes in ({'processedPixelCount': 1}, {'maximumOutputLongEdge': 1600},
                    {'selectedIndices': [0, 59, 120]}, {'selectedIndices': [0, 59, 59]},
                    {'originalFrameCount': 10001}, {'schemaVersion': True},
                    {'scaleDigest': 'secret'}, {'token': 'must-not-export'}):
        response = submit(client, with_client_metadata(payload, **changes), job_id=str(uuid.uuid4()))
        assert response.status_code == 400 and response.json['error']['code'] == 'invalid_scan'
    # A declaration cannot bypass raw resource processing bounds or mislabel an oversized upload.
    response = submit(client, with_client_metadata(many_frame_zip()), job_id=str(uuid.uuid4()))
    assert response.status_code == 400
    assert len(submissions) == 1
