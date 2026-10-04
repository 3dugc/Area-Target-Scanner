"""Deployment smoke must exercise the protected public API and integrity contract."""
import hashlib
import io
import json
import urllib.error

import pytest

from tools.deployment import smoke


@pytest.mark.parametrize('corruption', [None, 'size', 'sha256'])
def test_smoke_exercises_capability_retry_and_exact_result(monkeypatch, corruption):
    calls = []
    result_bytes = b'exact ZIP bytes'
    job_id = None
    owner = None
    submitted = 0
    class Response(io.BytesIO):
        def __init__(self, body, status=200):
            super().__init__(body)
            self.status = status
            self.headers = {}
    def urlopen(request, **kwargs):
        nonlocal job_id, owner, submitted
        path = __import__('urllib.parse', fromlist=['urlsplit']).urlsplit(request.full_url).path
        auth = request.get_header('Authorization')
        calls.append((path, request.get_method(), auth))
        if path == '/':
            return Response(b'page')
        assert path.startswith('/api/v1/') or path.startswith('/api/status/') or path.startswith('/api/download/')
        if path == '/api/v1/jobs':
            submitted += 1
            job_id = request.get_header('Idempotency-key')
            owner = auth
            assert len(owner.removeprefix('Bearer ')) == 64
            return Response(json.dumps({'job_id': job_id, 'status': 'queued'}).encode(), 202 if submitted == 1 else 200)
        if path.startswith('/api/status/') or path.startswith('/api/download/'):
            raise urllib.error.HTTPError(request.full_url, 404, 'missing', {}, io.BytesIO(b'{}'))
        if auth != owner:
            code = 401 if auth is None else 404
            raise urllib.error.HTTPError(request.full_url, code, 'denied', {}, io.BytesIO(json.dumps({'error': {'code': 'missing_or_invalid_token' if code == 401 else 'job_not_found', 'message': 'denied', 'retryable': False}}).encode()))
        if path.endswith('/result'):
            return Response(result_bytes)
        result = {'url': f'/api/v1/jobs/{job_id}/result', 'format': 'area-target-bundle',
                  'size_bytes': len(result_bytes) + (1 if corruption == 'size' else 0),
                  'sha256': '0' * 64 if corruption == 'sha256' else hashlib.sha256(result_bytes).hexdigest()}
        return Response(json.dumps({'job_id': job_id, 'status': 'completed', 'stage': 'completed', 'result': result}).encode())
    monkeypatch.setattr(smoke.urllib.request, 'urlopen', urlopen)
    monkeypatch.setattr(smoke, 'verify_bundle', lambda *_: {'verified': True})
    if corruption:
        with pytest.raises(ValueError, match='byte|SHA256'):
            smoke.run_smoke('https://example.test', 30)
    else:
        assert smoke.run_smoke('https://example.test', 30)['verified'] is True
        assert submitted == 2
        assert any(path.startswith('/api/status/') for path, _, _ in calls)
        assert any(path.endswith('/result') and token == owner for path, _, token in calls)


def test_large_fixture_reproduces_original_total_pixel_failure(tmp_path):
    import struct
    import zipfile
    path = smoke.create_fixture(tmp_path / 'large.zip', large_scan=True)
    with zipfile.ZipFile(path) as data:
        manifest = json.loads(data.read('manifest.json'))
        frames = manifest['frames']
        assert len(frames) == 100
        assert sum(f['image']['width'] * f['image']['height'] for f in frames) == 276_480_000
        assert [f['index'] for f in frames] == list(range(100))
        for frame in frames:
            png = data.read(frame['imageFile'])
            assert struct.unpack('>II', png[16:24]) == (1920, 1440)
        assert path.stat().st_size < 50 * 1024 * 1024


def test_large_smoke_requires_actual_bounded_preparation_with_scan_coverage():
    metadata = {'schemaVersion': 1, 'policy': 'mobile-scan-preparation-v1', 'policyVersion': 1,
                'profile': 'fast', 'preparedBy': 'server', 'originalFrameCount': 100,
                'selectedFrameCount': 80, 'selectedIndices': [i * 99 // 79 for i in range(80)],
                'processedPixelCount': 153_600_000, 'maximumOutputLongEdge': 1600,
                'resizedFrameCount': 80, 'scaleDigest': 'a' * 64}
    smoke.verify_large_preparation(metadata)
    for change in ({'originalFrameCount': 72}, {'selectedFrameCount': 100},
                   {'processedPixelCount': 204_800_000}, {'maximumOutputLongEdge': 1920},
                   {'selectedIndices': list(range(80))}):
        with pytest.raises(ValueError):
            smoke.verify_large_preparation({**metadata, **change})
