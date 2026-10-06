"""Deployment smoke must exercise the protected public API and integrity contract."""
import hashlib
import io
import json
import sqlite3
import struct
import urllib.error
import urllib.parse
import zipfile

import pytest

from tools.deployment import smoke


@pytest.mark.parametrize('corruption', [None, 'size', 'sha256'])
def test_smoke_exercises_capability_retry_and_exact_result(monkeypatch, corruption):
    monkeypatch.setenv('AREA_TARGET_USERNAME', 'test-user')
    monkeypatch.setenv('AREA_TARGET_PASSWORD', 'test-only-password')
    calls = []
    result_bytes = b'exact ZIP bytes'
    job_id = None
    owner = None
    submitted = 0
    submitted_body = None
    anonymous_posts = []
    multipart_bodies = []
    original_multipart = smoke.multipart_fixture
    def multipart_fixture(*args, **kwargs):
        body, content_type = original_multipart(*args, **kwargs)
        multipart_bodies.append(body)
        return body, content_type
    class Response(io.BytesIO):
        def __init__(self, body, status=200):
            super().__init__(body)
            self.status = status
            self.headers = {}
    def urlopen(request, **kwargs):
        nonlocal job_id, owner, submitted, submitted_body
        path = __import__('urllib.parse', fromlist=['urlsplit']).urlsplit(request.full_url).path
        auth = request.get_header('Authorization')
        headers = {name.lower(): value for name, value in request.header_items()}
        session = headers.get('x-area-target-session')
        calls.append((path, request.get_method(), auth))
        if path == '/healthz':
            return Response(b'{"status":"ok"}')
        if path == '/api/auth/login':
            assert request.get_method() == 'POST'
            assert json.loads(request.data) == {'username': 'test-user', 'password': 'test-only-password'}
            return Response(json.dumps({'username': 'test-user', 'session_token': 'service-session',
                                        'csrf_token': 'service-csrf', 'expires_at': 2_000_000_000}).encode())
        if session != 'service-session':
            if request.get_method() == 'POST':
                anonymous_posts.append(path)
                assert len(request.data or b'') <= 1024, 'Anonymous auth probes must not send a scan body'
            raise urllib.error.HTTPError(request.full_url, 401, 'login required', {},
                                         io.BytesIO(b'{"error":{"code":"auth_required","message":"Login required","retryable":false}}'))
        assert path.startswith('/api/v1/') or path.startswith('/api/status/') or path.startswith('/api/download/')
        if path == '/api/v1/jobs':
            assert headers.get('x-csrf-token') == 'service-csrf'
            assert request.data == multipart_bodies[0]
            assert len(request.data) > 1024
            if submitted_body is not None:
                assert request.data == submitted_body
                assert auth == owner
                assert request.get_header('Idempotency-key') == job_id
            submitted_body = request.data
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
    monkeypatch.setattr(smoke, 'multipart_fixture', multipart_fixture)
    monkeypatch.setattr(smoke, 'wait_ready', lambda *_: None)
    monkeypatch.setattr(smoke, 'verify_bundle', lambda *_: {'verified': True})
    if corruption:
        with pytest.raises(ValueError, match='byte|SHA256'):
            smoke.run_smoke('https://example.test', 30)
    else:
        assert smoke.run_smoke('https://example.test', 30)['verified'] is True
        assert submitted == 2
        assert anonymous_posts == ['/api/upload', '/api/v1/jobs']
        assert ('/api/upload', 'POST', None) in calls
        assert any(path == '/api/auth/login' for path, _, _ in calls)
        assert any(path.startswith('/api/status/') for path, _, _ in calls)
        assert any(path.endswith('/result') and token == owner for path, _, token in calls)


def test_readiness_uses_public_health_endpoint(monkeypatch):
    paths = []
    monkeypatch.setattr(smoke, 'fetch', lambda url, *_: paths.append(url) or b'{"status":"ok"}')
    smoke.wait_ready('https://example.test', smoke.time.monotonic() + 5)
    assert paths == ['https://example.test/healthz']


@pytest.mark.parametrize('missing', ['AREA_TARGET_USERNAME', 'AREA_TARGET_PASSWORD'])
def test_smoke_requires_environment_credentials_before_network(monkeypatch, missing):
    monkeypatch.setenv('AREA_TARGET_USERNAME', 'test-user')
    monkeypatch.setenv('AREA_TARGET_PASSWORD', 'test-only-password')
    monkeypatch.delenv(missing)
    monkeypatch.setattr(smoke, 'wait_ready', lambda *_: pytest.fail('Network readiness must not run without credentials'))
    monkeypatch.setattr(smoke, 'fetch_response', lambda *_: pytest.fail('HTTP requests must not run without credentials'))
    with pytest.raises(ValueError, match='AREA_TARGET_USERNAME.*AREA_TARGET_PASSWORD'):
        smoke.run_smoke('https://example.test', 5)


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


V2_POLICY = 'mobile-scan-preparation-v2'
CRITICAL_CAPABILITY = {
    'version': 'critical-frame-protection-v1', 'riskVersion': 'gray-quality-risk-v1',
    'maximumProtectedFrames': 8, 'maximumProtectedLongEdge': 1920,
    'sharpnessThreshold': 16, 'contrastThreshold': 20,
}
V2_SIZES = [(1920, 1440), (1600, 1200), (384, 256), (384, 256)]


def _scale_digest(count):
    scales = [{'index': i, 'width': w, 'height': h, 'outputWidth': w, 'outputHeight': h}
              for i, (w, h) in enumerate(V2_SIZES[:count])]
    return hashlib.sha256(json.dumps(scales, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _v2_client():
    selection = {'capacityTier': 100, 'policy': V2_POLICY, 'selectedIndices': list(range(4)),
                 'selectionVersion': 'upload-all-v2'}
    return {'schemaVersion': 1, 'policy': V2_POLICY, 'policyVersion': 2, 'profile': 'fast',
            'preparedBy': 'client', 'originalFrameCount': 4, 'receivedFrameCount': 4,
            'selectedFrameCount': 4, 'selectedIndices': list(range(4)),
            'processedPixelCount': sum(w * h for w, h in V2_SIZES), 'resizedFrameCount': 0,
            'maximumOutputLongEdge': 1920, 'scaleDigest': _scale_digest(4),
            'capacityTier': 100, 'selectionVersion': 'upload-all-v2',
            'selectionDigest': hashlib.sha256(json.dumps(selection, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'criticalFrameProtection': {'version': 'critical-frame-protection-v1',
                'riskVersion': 'gray-quality-risk-v1', 'protectedIndices': [0], 'candidateFrameCount': 1}}


def _v2_verified():
    return {'keyframes': 3, 'features': 60, 'akaze_features': 0, 'vocabulary': 2,
            'keyframe_ids': [0, 1, 2], 'keyframe_feature_counts': {'0': 20, '1': 20, '2': 20},
            'keyframe_pixel_bounds': {'0': {'max_x': 1719, 'max_y': 1319},
                                      '1': {'max_x': 119, 'max_y': 119},
                                      '2': {'max_x': 119, 'max_y': 119}},
            'scan_preparation': {'schemaVersion': 1, 'policy': V2_POLICY, 'policyVersion': 2,
                'profile': 'fast', 'preparedBy': 'server', 'originalFrameCount': 4,
                'receivedFrameCount': 4, 'selectedFrameCount': 3, 'selectedIndices': [0, 1, 2],
                'duplicateFrameCount': 1,
                'duplicateGroups': [{'representativeIndex': 2, 'duplicateIndices': [3]}],
                'selectionVersion': 'pose-visual-dedup-v1', 'capacityTier': 100,
                'selectionDigest': 'f42a4e521487c1f011c4949a9c7bc3a2813f439746d1344c3884a5c2b777ee9e',
                'maximumTotalPixels': 200_000_000,
                'processedPixelCount': sum(w * h for w, h in V2_SIZES[:3]),
                'maximumOutputLongEdge': 1920, 'resizedFrameCount': 0, 'scaleDigest': _scale_digest(3),
                'criticalFrameProtection': {'version': 'critical-frame-protection-v1',
                    'riskVersion': 'gray-quality-risk-v1', 'candidateFrameCount': 1,
                    'requestedProtectedIndices': [0], 'protectedIndices': [0],
                    'deduplicatedProtectedIndices': []}},
            'client_preparation': _v2_client(),
            'feature_selection': {'version': 'prepared-coverage-v2',
                'featureBudgetVersion': 'balanced-mobile-features-v1', 'featureBudgetProfile': 'fast',
                'inputFrameCount': 3, 'selectedFrameCount': 3, 'retainedIndices': [0, 1, 2],
                'orbFeatureCount': 60, 'akazeFeatureCount': 0, 'vocabularySize': 2,
                'retainedKeyframeCount': 3, 'insufficientFeatureFrameCount': 0,
                'insufficientFeatureFrameIndices': [], 'unreadableFrameCount': 0, 'unreadableFrameIndices': []}}


def test_v2_fixture_has_actual_mixed_rasters_complete_provenance_and_one_duplicate(tmp_path):
    from PIL import Image
    path = smoke.create_fixture(tmp_path / 'v2.zip', preparation_v2=True)
    with zipfile.ZipFile(path) as data:
        manifest = json.loads(data.read('manifest.json'))
        assert manifest['clientPreparation'] == _v2_client()
        frames = manifest['frames']
        assert [f['index'] for f in frames] == [0, 1, 2, 3]
        images = [data.read(f['imageFile']) for f in frames]
        assert images[2] == images[3] and len(set(images)) == 3
        assert frames[2]['transform'] == frames[3]['transform']
        assert [f['transform'][12] for f in frames] == [-.25, 0, .25, .25]
        for frame, pixels, size in zip(frames, images, V2_SIZES):
            with Image.open(io.BytesIO(pixels)) as raster:
                raster.load()
                assert raster.size == size
            assert frame['image'] == dict(zip(('width', 'height'), size))
            assert frame['intrinsics']['cx'] == size[0] / 2
            assert frame['intrinsics']['cy'] == size[1] / 2
        assert path.stat().st_size < 50 * 1024 * 1024


def test_v2_output_requires_dedup_protection_and_actual_three_frame_database():
    smoke.verify_v2_preparation(_v2_verified())


@pytest.mark.parametrize('corruption', ['v1', 'no_dedup', 'protection_lost', 'wrong_pixels',
                                      'wrong_scale', 'missing_client', 'old_features', 'missing_view',
                                      'fake_resolution', 'too_many_features', 'too_many_words'])
def test_v2_output_rejects_fallback_or_unexercised_functionality(corruption):
    result = _v2_verified()
    preparation = result['scan_preparation']
    if corruption == 'v1':
        preparation.update(policy='mobile-scan-preparation-v1', policyVersion=1)
    elif corruption == 'no_dedup':
        preparation.update(selectedFrameCount=4, duplicateFrameCount=0, selectedIndices=[0, 1, 2, 3])
    elif corruption == 'protection_lost':
        preparation['criticalFrameProtection']['protectedIndices'] = []
    elif corruption == 'wrong_pixels':
        preparation['processedPixelCount'] -= 1
    elif corruption == 'wrong_scale':
        preparation['scaleDigest'] = 'a' * 64
    elif corruption == 'missing_client':
        result['client_preparation'] = None
    elif corruption == 'old_features':
        result['feature_selection']['featureBudgetVersion'] = 'legacy'
    elif corruption == 'missing_view':
        result['keyframe_ids'] = [0, 1]
    elif corruption == 'fake_resolution':
        result['keyframe_pixel_bounds']['0'] = {'max_x': 1500, 'max_y': 1100}
    elif corruption == 'too_many_features':
        result['features'] = 200_001
    elif corruption == 'too_many_words':
        result['vocabulary'] = 501
    with pytest.raises(ValueError):
        smoke.verify_v2_preparation(result)


def test_verify_bundle_returns_actual_sqlite_views_and_protection_diagnostics(tmp_path):
    expected = _v2_verified()
    database = tmp_path / 'input.db'
    with sqlite3.connect(database) as connection:
        connection.executescript('''CREATE TABLE keyframes(id INTEGER,pose BLOB);
            CREATE TABLE features(keyframe_id INTEGER,x REAL,y REAL,x3d REAL,y3d REAL,z3d REAL,descriptor BLOB);
            CREATE TABLE vocabulary(word_id INTEGER);''')
        for i, tx in enumerate([-.25, 0, .25]):
            pose = [1, 0, 0, tx, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            connection.execute('INSERT INTO keyframes VALUES(?,?)', (i, struct.pack('<16d', *pose)))
            for n in range(20):
                x, y = (1700 + n, 1300 + n) if i == 0 else (100 + n, 100 + n)
                connection.execute('INSERT INTO features VALUES(?,?,?,?,?,?,?)', (i, x, y, 0, 0, -3, bytes(32)))
        connection.executemany('INSERT INTO vocabulary VALUES(?)', [(0,), (1,)])
    document = {'asset': {'version': '2.0'}, 'meshes': [{'primitives': [{'attributes': {'POSITION': 0}}]}],
                'accessors': [{'count': 3}]}
    chunk = json.dumps(document).encode()
    chunk += b' ' * (-len(chunk) % 4)
    binary = bytes(36)
    glb = (struct.pack('<4sII', b'glTF', 2, 28 + len(chunk) + len(binary))
           + struct.pack('<II', len(chunk), 0x4e4f534a) + chunk
           + struct.pack('<II', len(binary), 0x004e4942) + binary)
    manifest = {'version': '2.0', 'format': 'glb', 'meshFile': 'optimized.glb',
                'featureDbFile': 'features.db', 'keyframeCount': 3,
                'bounds': {'min': [-4, -3, -3.2], 'max': [4, 3, -3]},
                'scanPreparation': expected['scan_preparation'],
                'clientPreparation': expected['client_preparation'],
                'producer': {'keyframeSelection': expected['feature_selection']}}
    bundle = io.BytesIO()
    with zipfile.ZipFile(bundle, 'w') as archive:
        archive.writestr('manifest.json', json.dumps(manifest))
        archive.writestr('features.db', database.read_bytes())
        archive.writestr('optimized.glb', glb)
    actual = smoke.verify_bundle(bundle.getvalue(), tmp_path)
    for name in expected:
        assert actual[name] == expected[name]
    smoke.verify_v2_preparation(actual)


@pytest.mark.parametrize('bad_capability', [False, True])
def test_v2_http_negotiation_and_saved_retry_bytes(monkeypatch, bad_capability):
    monkeypatch.setenv('AREA_TARGET_USERNAME', 'test-user')
    monkeypatch.setenv('AREA_TARGET_PASSWORD', 'test-only-password')
    monkeypatch.setattr(smoke, 'wait_ready', lambda *_: None)
    monkeypatch.setattr(smoke, 'verify_bundle', lambda *_: _v2_verified())
    bundle = b'checked bundle bytes'
    bodies, identities, paths = [], [], []
    owner = job_id = None
    def response(url, deadline, data=None, headers=None):
        nonlocal owner, job_id
        parsed = urllib.parse.urlsplit(url)
        path, headers = parsed.path, headers or {}
        paths.append(path + ('?' + parsed.query if parsed.query else ''))
        if path == '/api/auth/login':
            return 200, json.dumps({'session_token': 'session', 'csrf_token': 'csrf'}).encode()
        if headers.get('X-Area-Target-Session') != 'session':
            return 401, b'{}'
        if path == '/api/v1/processing-requirements':
            assert parsed.query == 'policy=' + V2_POLICY
            capability = {**CRITICAL_CAPABILITY, 'version': 'unknown'} if bad_capability else CRITICAL_CAPABILITY
            return 200, json.dumps({'schemaVersion': 1, 'policy': V2_POLICY, 'policyVersion': 2,
                'capacityTier': 100, 'criticalFrameProtection': capability,
                'profiles': {'fast': {'maxFrames': 100, 'maximumLongEdge': 1600,
                                      'minimumLongEdge': 1024, 'maximumTotalPixels': 200_000_000}}}).encode()
        if path == '/api/v1/jobs':
            owner, job_id = headers['Authorization'], headers['Idempotency-Key']
            bodies.append(data)
            identities.append((owner, job_id, headers['Content-Type']))
            return (202 if len(bodies) == 1 else 200), json.dumps({'job_id': job_id}).encode()
        if path.startswith('/api/status/') or path.startswith('/api/download/'):
            return 404, b'{}'
        if headers.get('Authorization') != owner:
            return (401 if headers.get('Authorization') is None else 404), b'{}'
        if path.endswith('/result'):
            return 200, bundle
        return 200, json.dumps({'job_id': job_id, 'status': 'completed', 'stage': 'completed',
            'result': {'format': 'area-target-bundle', 'url': f'/api/v1/jobs/{job_id}/result',
                       'size_bytes': len(bundle), 'sha256': hashlib.sha256(bundle).hexdigest()}}).encode()
    monkeypatch.setattr(smoke, 'fetch_response', response)
    if bad_capability:
        with pytest.raises(ValueError, match='capability'):
            smoke.run_smoke('https://example.test', 30, preparation_v2=True)
        assert not bodies
    else:
        result = smoke.run_smoke('https://example.test', 30, preparation_v2=True)
        assert result['preparation_v2'] is True
        assert len(bodies) == 2 and bodies[0] == bodies[1] and identities[0] == identities[1]
        assert '/api/v1/processing-requirements?policy=' + V2_POLICY in paths


def test_cli_v2_fixture_mode_and_exclusive_large_mode(tmp_path, monkeypatch, capsys):
    path = tmp_path / 'cli-v2.zip'
    monkeypatch.setattr(smoke.sys, 'argv', ['smoke', '--fixture-only', str(path), '--preparation-v2'])
    assert smoke.main() == 0
    assert json.loads(capsys.readouterr().out)['frames'] == 4
    monkeypatch.setattr(smoke.sys, 'argv', ['smoke', '--fixture-only', str(path), '--preparation-v2', '--large-scan'])
    with pytest.raises(SystemExit) as error:
        smoke.main()
    assert error.value.code == 2


@pytest.mark.parametrize('corrupted', [None, 'corrupted'])
def test_v2_output_rejects_missing_or_forged_server_selection_digest(corrupted):
    result = _v2_verified()
    if corrupted is None:
        result['scan_preparation'].pop('selectionDigest', None)
    else:
        result['scan_preparation']['selectionDigest'] = corrupted
    with pytest.raises(ValueError, match='selectionDigest'):
        smoke.verify_v2_preparation(result)
