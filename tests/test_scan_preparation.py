"""Real image preparation keeps the raw scan unchanged and bounds downstream work."""
import hashlib
import json
import zipfile

import pytest
from PIL import Image

from tests.test_mobile_scan_preparation import many_frame_zip


def raw_scan(tmp_path, count=120, size=(1920, 1440)):
    root = tmp_path / 'raw'
    root.mkdir()
    import io
    with zipfile.ZipFile(io.BytesIO(many_frame_zip(count, size))) as archive:
        archive.extractall(root)
    return root


def digest_tree(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob('*') if path.is_file()}


@pytest.mark.parametrize('profile', ['fast', 'quality'])
def test_long_scan_selects_full_extent_scales_each_calibration_and_keeps_raw(tmp_path, profile):
    from processing_pipeline.scan_preparation import prepare_scan
    from processing_pipeline.scan_security import validate_scan
    raw = raw_scan(tmp_path, size=(1919, 1439))
    before = digest_tree(raw)
    original = json.loads((raw / 'manifest.json').read_text())
    prepared = prepare_scan(raw, tmp_path / 'prepared', profile=profile, uv_unwrap=True)
    manifest = json.loads((prepared.root / 'manifest.json').read_text())
    indices = prepared.metadata['selectedIndices']
    assert len(indices) == 80 and indices[0] == 0 and indices[-1] == 119
    assert indices == sorted(set(indices))
    assert prepared.metadata['originalFrameCount'] == 120
    assert prepared.metadata['selectedFrameCount'] == 80
    assert prepared.metadata['processedPixelCount'] == 80 * 1600 * 1199
    assert prepared.metadata['resizedFrameCount'] == 80
    assert prepared.metadata['preparedBy'] == 'server'
    assert prepared.metadata['profile'] == profile
    assert len(prepared.metadata['scaleDigest']) == 64
    for index, frame in zip(indices, manifest['frames']):
        old = original['frames'][index]
        assert frame['index'] == old['index'] and frame['timestamp'] == old['timestamp']
        assert frame['transform'] == old['transform']
        assert frame['imageOrientation'] == old['imageOrientation']
        with Image.open(prepared.root / frame['imageFile']) as image:
            assert image.size == (1600, 1199)
        assert frame['image'] == {'width': 1600, 'height': 1199}
        assert frame['intrinsics']['fx'] == pytest.approx(old['intrinsics']['fx'] * 1600 / 1919)
        assert frame['intrinsics']['cx'] == pytest.approx(old['intrinsics']['cx'] * 1600 / 1919)
        assert frame['intrinsics']['fy'] == pytest.approx(old['intrinsics']['fy'] * 1199 / 1439)
        assert frame['intrinsics']['cy'] == pytest.approx(old['intrinsics']['cy'] * 1199 / 1439)
    assert len(validate_scan(prepared.root, True, prepare_uv=True)) == 80
    assert digest_tree(raw) == before
    assert len(list((prepared.root / 'images').iterdir())) == 80


def test_square_frames_obey_actual_aggregate_not_just_long_edge(tmp_path):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=80, size=(2048, 2048))
    prepared = prepare_scan(raw, tmp_path / 'prepared', uv_unwrap=True)
    frames = json.loads((prepared.root / 'manifest.json').read_text())['frames']
    assert sum(f['image']['width'] * f['image']['height'] for f in frames) == 80 * 1581 ** 2
    assert prepared.metadata['processedPixelCount'] <= 200_000_000
    assert prepared.metadata['maximumOutputLongEdge'] == 1581


def test_already_prepared_small_frames_keep_exact_encoded_image_bytes(tmp_path, monkeypatch):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=3, size=(80, 60))
    def no_decode(*args, **kwargs):
        raise AssertionError('Unchanged images must use verified-byte copy without a redundant decode')
    monkeypatch.setattr(Image.Image, 'load', no_decode)
    prepared = prepare_scan(raw, tmp_path / 'prepared', uv_unwrap=True)
    frames = json.loads((prepared.root / 'manifest.json').read_text())['frames']
    assert prepared.metadata['resizedFrameCount'] == 0
    assert prepared.metadata['selectedIndices'] == [0, 1, 2]
    for index, frame in enumerate(frames):
        assert (prepared.root / frame['imageFile']).read_bytes() == (raw / f'images/{index}.jpg').read_bytes()


def test_legacy_scan_gets_per_frame_calibration_without_mutating_raw(tmp_path):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=2, size=(1920, 1440))
    frames = json.loads((raw / 'manifest.json').read_text())['frames']
    for frame in frames:
        frame.pop('image')
    (raw / 'manifest.json').unlink()
    (raw / 'poses.json').write_text(json.dumps({'frames': frames}))
    before = digest_tree(raw)
    prepared = prepare_scan(raw, tmp_path / 'prepared', uv_unwrap=True)
    output = json.loads((prepared.root / 'manifest.json').read_text())['frames']
    assert [frame['image'] for frame in output] == [{'width': 1600, 'height': 1200}] * 2
    assert output[1]['intrinsics']['fx'] == pytest.approx(1280)
    assert digest_tree(raw) == before


def test_preparation_refuses_to_replace_or_descend_into_raw(tmp_path):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=1, size=(32, 24))
    before = digest_tree(raw)
    for destination in (raw, raw / 'derived', tmp_path):
        with pytest.raises(ValueError):
            prepare_scan(raw, destination, uv_unwrap=True)
    assert digest_tree(raw) == before


def test_client_preparation_is_preserved_separately_and_never_replaces_actual_server_counts(tmp_path):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=3, size=(80, 60))
    path = raw / 'manifest.json'
    manifest = json.loads(path.read_text())
    client_metadata = {'schemaVersion': 1, 'policy': 'mobile-scan-preparation-v1', 'policyVersion': 1,
                       'profile': 'fast', 'preparedBy': 'client', 'originalFrameCount': 120,
                       'selectedFrameCount': 3, 'selectedIndices': [0, 59, 119], 'processedPixelCount': 14400,
                       'resizedFrameCount': 3, 'maximumOutputLongEdge': 80, 'scaleDigest': 'a' * 64}
    manifest['clientPreparation'] = client_metadata
    path.write_text(json.dumps(manifest))
    prepared = prepare_scan(raw, tmp_path / 'prepared', uv_unwrap=True)
    assert prepared.client_preparation == client_metadata
    assert prepared.metadata['originalFrameCount'] == 3
    assert prepared.metadata['selectedIndices'] == [0, 1, 2]
    manifest['clientPreparation']['selectedIndices'] = [0, 0, 119]
    path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        prepare_scan(raw, tmp_path / 'bad', uv_unwrap=True)


def test_individual_image_limit_and_default_aggregate_limit_remain(tmp_path):
    from processing_pipeline.scan_security import validate_scan
    raw = raw_scan(tmp_path, count=73)
    with pytest.raises(ValueError, match='total pixel'):
        validate_scan(raw, True)
    assert len(validate_scan(raw, True, max_total_frame_pixels=None)) == 73
    manifest_path = raw / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['frames'][0]['image']['width'] = 8193
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        validate_scan(raw, True, max_total_frame_pixels=None)


def test_preparation_does_not_overwrite_existing_model_texture_named_like_generated_frame(tmp_path):
    from processing_pipeline.scan_preparation import prepare_scan
    raw = raw_scan(tmp_path, count=1, size=(32, 24))
    texture = raw / 'images' / 'prepared_00000.jpg'
    Image.new('RGB', (16, 16), 'red').save(texture)
    (raw / 'model.obj').write_text('mtllib model.mtl\nv 0 0 -1\nv 1 0 -1\nv 0 1 -1\nf 1 2 3\n')
    (raw / 'model.mtl').write_text('newmtl material\nmap_Kd images/prepared_00000.jpg\n')
    Image.new('RGB', (16, 16), 'blue').save(raw / 'texture.jpg')
    before = texture.read_bytes()
    prepared = prepare_scan(raw, tmp_path / 'prepared')
    assert (prepared.root / 'images/prepared_00000.jpg').read_bytes() == before
    frame = json.loads((prepared.root / 'manifest.json').read_text())['frames'][0]
    assert frame['imageFile'] != 'images/prepared_00000.jpg'
    assert (prepared.root / frame['imageFile']).read_bytes() == (raw / 'images/0.jpg').read_bytes()
