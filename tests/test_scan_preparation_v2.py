"""V2 policies preserve distinct view counts and enforce actual resource budgets."""
import json

import pytest

from processing_pipeline.scan_preparation import (POLICY_V2, WorkingImagePolicy,
    processing_requirements, working_image_sizes, prepare_scan)
from tests.test_scan_preparation import raw_scan, digest_tree


@pytest.mark.parametrize('count,budget', [(100, 200_000_000), (500, 600_000_000)])
def test_v2_dimensions_preserve_count_and_use_actual_total_pixels(count, budget):
    policy = WorkingImagePolicy(count, 1600, 1024, budget)
    output = working_image_sizes([(1919, 1439)] * count, policy)
    assert len(output) == count
    assert sum(w * h for w, h in output) <= budget
    assert min(max(size) for size in output) >= 1024
    assert working_image_sizes([(640, 480)], policy) == [(640, 480)]


def test_v2_cannot_sacrifice_resolution_or_viewpoints_to_pass_budget():
    with pytest.raises(ValueError, match='coverage_budget_exceeded'):
        working_image_sizes([(1920, 1440)] * 500, WorkingImagePolicy(500, 1600, 1024, 200_000_000))
    with pytest.raises(ValueError, match='coverage_budget_exceeded'):
        working_image_sizes([(640, 480)] * 101, WorkingImagePolicy(100, 1600, 1024, 200_000_000))


def test_v2_mixed_aspects_and_small_sources_preserve_floors():
    dimensions = [(1919, 1439), (1439, 1919), (2048, 2048), (640, 480)] * 25
    output = working_image_sizes(dimensions, WorkingImagePolicy(100, 1600, 1024, 150_000_000))
    assert len(output) == 100 and sum(w * h for w, h in output) <= 150_000_000
    for source, result in zip(dimensions, output):
        assert min(max(source), 1024) <= max(result) <= min(max(source), 1600)
        assert all(new <= old for new, old in zip(result, source))
    assert output[3] == (640, 480)


def test_v2_actual_resizing_keeps_source_ids_poses_and_per_axis_calibration(tmp_path):
    raw = raw_scan(tmp_path, count=2, size=(1919, 1439))
    path = raw / 'manifest.json'
    original = json.loads(path.read_text())
    original['frames'][0]['index'] = 101
    original['frames'][1]['index'] = 901
    path.write_text(json.dumps(original))
    result = prepare_scan(raw, tmp_path / 'prepared', policy=POLICY_V2, uv_unwrap=True)
    output = json.loads((result.root / 'manifest.json').read_text())['frames']
    for source, frame in zip(original['frames'], output):
        assert frame['index'] == source['index']
        assert frame['timestamp'] == source['timestamp'] and frame['transform'] == source['transform']
        assert frame['image'] == {'width': 1600, 'height': 1199}
        for key in ('fx', 'cx'):
            assert frame['intrinsics'][key] == pytest.approx(source['intrinsics'][key] * 1600 / 1919)
        for key in ('fy', 'cy'):
            assert frame['intrinsics'][key] == pytest.approx(source['intrinsics'][key] * 1199 / 1439)


def test_v2_requirements_are_negotiated_and_500_requires_explicit_enable(monkeypatch):
    monkeypatch.delenv('AREA_TARGET_PREPARATION_TIER', raising=False)
    legacy = processing_requirements()
    assert set(legacy) == {'schemaVersion', 'policy', 'policyVersion', 'profiles', 'safety'}
    assert legacy['policyVersion'] == 1
    requirements = processing_requirements(policy=POLICY_V2)
    assert requirements['capacityTier'] == 100
    assert requirements['keyframeSelection']['version'] == 'pose-visual-dedup-v1'
    assert requirements['profiles']['quality']['minimumLongEdge'] == 1024
    monkeypatch.setenv('AREA_TARGET_PREPARATION_TIER', '500')
    requirements = processing_requirements(policy=POLICY_V2)
    assert requirements['capacityTier'] == 500
    assert requirements['profiles']['quality']['maximumTotalPixels'] == 600_000_000
    with pytest.raises(ValueError, match='unsupported_preparation_policy'):
        processing_requirements(policy='unknown')


@pytest.mark.parametrize('count', [100, 500])
def test_v2_real_scan_keeps_all_distinct_source_frames(tmp_path, monkeypatch, count):
    monkeypatch.setenv('AREA_TARGET_PREPARATION_TIER', str(count))
    raw = raw_scan(tmp_path, count=count, size=(80, 60))
    before = digest_tree(raw)
    result = prepare_scan(raw, tmp_path / 'prepared', policy=POLICY_V2, capacity=count, uv_unwrap=True)
    assert result.metadata['selectedFrameCount'] == count
    assert result.metadata['receivedFrameCount'] == count
    assert result.metadata['duplicateFrameCount'] == 0
    assert result.metadata['selectedIndices'] == list(range(count))
    assert result.metadata['selectionVersion'] == 'pose-visual-dedup-v1'
    assert len(result.metadata['selectionDigest']) == 64
    output = json.loads((result.root / 'manifest.json').read_text())
    assert [f['index'] for f in output['frames']] == list(range(count))
    assert digest_tree(raw) == before


def test_v2_budget_failure_keeps_raw_and_creates_no_partial_working_scan(tmp_path, monkeypatch):
    monkeypatch.delenv('AREA_TARGET_PREPARATION_TIER', raising=False)
    raw = raw_scan(tmp_path, count=101, size=(80, 60))
    before = digest_tree(raw)
    with pytest.raises(ValueError, match='coverage_budget_exceeded'):
        prepare_scan(raw, tmp_path / 'prepared', policy=POLICY_V2, uv_unwrap=True)
    assert not (tmp_path / 'prepared').exists()
    assert digest_tree(raw) == before


def test_v2_more_uploaded_frames_can_fit_after_authoritative_dedup(tmp_path):
    import io
    import numpy as np
    from PIL import Image
    raw = raw_scan(tmp_path, count=101, size=(320, 240))
    pixels = np.random.default_rng(617).integers(0, 256, (240, 320), dtype=np.uint8)
    encoded = io.BytesIO()
    Image.fromarray(pixels).save(encoded, format='PNG')
    path = raw / 'manifest.json'
    source = json.loads(path.read_text())
    for frame in source['frames']:
        frame['transform'][12] = 0
        frame['run'] = 8
        (raw / frame['imageFile']).write_bytes(encoded.getvalue())
    path.write_text(json.dumps(source))
    before = digest_tree(raw)
    result = prepare_scan(raw, tmp_path / 'prepared', policy=POLICY_V2, uv_unwrap=True)
    assert result.metadata['receivedFrameCount'] == 101
    assert result.metadata['selectedFrameCount'] == 1
    assert result.metadata['duplicateFrameCount'] == 100
    assert result.metadata['selectedIndices'] == [0]
    assert digest_tree(raw) == before
