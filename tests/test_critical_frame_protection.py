"""Protected views keep pixels without guessing the geometry eligibility gate."""
import json

import pytest

from processing_pipeline.scan_preparation import (
    POLICY_V2, WorkingImagePolicy, prepare_scan, processing_requirements,
    validate_client_preparation, working_image_sizes, upload_selection_digest,
)
from tests.test_scan_preparation import raw_scan, digest_tree


CAPABILITY = {
    'version': 'critical-frame-protection-v1', 'riskVersion': 'gray-quality-risk-v1',
    'maximumProtectedFrames': 8, 'maximumProtectedLongEdge': 1920,
    'sharpnessThreshold': 16, 'contrastThreshold': 20,
}


def protection(indices, candidates=None):
    return {'version': CAPABILITY['version'], 'riskVersion': CAPABILITY['riskVersion'],
            'protectedIndices': indices, 'candidateFrameCount': len(indices) if candidates is None else candidates}


def client_metadata(dimensions, indices, *, candidates=None):
    count = len(dimensions)
    return {'schemaVersion': 1, 'policy': POLICY_V2, 'policyVersion': 2, 'profile': 'fast',
            'preparedBy': 'client', 'originalFrameCount': count, 'selectedFrameCount': count,
            'selectedIndices': list(range(count)), 'processedPixelCount': sum(w * h for w, h in dimensions),
            'resizedFrameCount': 0, 'maximumOutputLongEdge': max(max(size) for size in dimensions),
            'scaleDigest': 'a' * 64, 'receivedFrameCount': count, 'capacityTier': 100,
            'selectionVersion': 'upload-all-v2', 'selectionDigest': upload_selection_digest(100, list(range(count))),
            'criticalFrameProtection': protection(indices, candidates)}


def validate(value, dimensions):
    return validate_client_preparation(value, frame_count=len(dimensions),
        actual_pixels=sum(w * h for w, h in dimensions), maximum_long_edge=max(map(max, dimensions)),
        dimensions=dimensions)


def test_capability_is_explicit_only_for_v2():
    assert 'criticalFrameProtection' not in processing_requirements()
    assert processing_requirements(policy=POLICY_V2)['criticalFrameProtection'] == CAPABILITY


@pytest.mark.parametrize('count,budget', [(100, 200_000_000), (500, 600_000_000)])
def test_mixed_square_budget_reserves_high_resolution_then_shares_remainder(count, budget):
    output = working_image_sizes([(2048, 2048)] * count,
        WorkingImagePolicy(count, 1600, 1024, budget), protected_indices=list(range(8)))
    assert output[:8] == [(1920, 1920)] * 8
    assert len(output) == count and sum(w * h for w, h in output) <= budget
    assert len(set(output[8:])) == 1
    assert all(1024 <= max(size) <= 1600 for size in output[8:])


def test_protected_minimum_budget_fails_without_reducing_protected_pixels():
    with pytest.raises(ValueError, match='coverage_budget_exceeded'):
        working_image_sizes([(1920, 1440)] * 2,
            WorkingImagePolicy(100, 1600, 1024, 3_000_000), protected_indices=[0])
    assert working_image_sizes([(640, 480), (80, 60)],
        WorkingImagePolicy(100, 1600, 1024, 200_000_000), protected_indices=[0]) == [(640, 480), (80, 60)]


def test_received_high_resolution_is_only_allowed_at_protected_actual_ordinals():
    dimensions = [(1920, 1440), (1600, 1200)]
    value = client_metadata(dimensions, [0])
    assert validate(value, dimensions) == value
    with pytest.raises(ValueError):
        validate(client_metadata(dimensions, [1]), dimensions)
    with pytest.raises(ValueError):
        validate(client_metadata([(1921, 1440), (1600, 1200)], [0]), [(1921, 1440), (1600, 1200)])


@pytest.mark.parametrize('changes', [
    {'version': 'unknown'}, {'riskVersion': 'unknown'}, {'extra': 0}, {'candidateFrameCount': True},
    {'candidateFrameCount': 0}, {'candidateFrameCount': 3}, {'protectedIndices': [True]},
    {'protectedIndices': [1, 0]}, {'protectedIndices': [0, 0]}, {'protectedIndices': [-1]},
    {'protectedIndices': [2]},
])
def test_client_extension_rejects_unknown_or_forged_protection(changes):
    dimensions = [(1600, 1200)] * 2
    value = client_metadata(dimensions, [0])
    value['criticalFrameProtection'].update(changes)
    with pytest.raises(ValueError):
        validate(value, dimensions)


def test_client_extension_requires_actual_dimensions_and_bounded_protection_count():
    dimensions = [(1600, 1200)] * 9
    with pytest.raises(ValueError):
        validate(client_metadata(dimensions, list(range(9))), dimensions)
    value = client_metadata(dimensions, [0])
    with pytest.raises(ValueError):
        validate_client_preparation(value, frame_count=9, actual_pixels=9 * 1600 * 1200,
                                    maximum_long_edge=1600)


def test_client_protected_pixels_pose_and_ids_survive_server_preparation(tmp_path):
    root = raw_scan(tmp_path, count=2)
    manifest_path = root / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['frames'][0]['index'] = 101
    manifest['frames'][1]['index'] = 901
    # Source 1 is already a normal upload raster with matching calibration.
    from PIL import Image
    with Image.open(root / 'images/1.jpg') as image:
        image.resize((1600, 1200)).save(root / 'images/1.jpg')
    frame = manifest['frames'][1]
    frame['image'] = {'width': 1600, 'height': 1200}
    frame['intrinsics'] = {k: v * 1600 / 1920 for k, v in frame['intrinsics'].items()}
    manifest['clientPreparation'] = client_metadata([(1920, 1440), (1600, 1200)], [0])
    manifest_path.write_text(json.dumps(manifest))
    before = digest_tree(root)
    result = prepare_scan(root, tmp_path / 'prepared', policy=POLICY_V2, uv_unwrap=True)
    frames = json.loads((result.root / 'manifest.json').read_text())['frames']
    assert frames[0]['image'] == {'width': 1920, 'height': 1440}
    assert (result.root / frames[0]['imageFile']).read_bytes() == (root / 'images/0.jpg').read_bytes()
    assert [f['index'] for f in frames] == [101, 901]
    assert frames[0]['intrinsics'] == manifest['frames'][0]['intrinsics']
    assert frames[0]['transform'] == manifest['frames'][0]['transform']
    assert frames[0]['timestamp'] == manifest['frames'][0]['timestamp']
    assert result.metadata['criticalFrameProtection']['protectedIndices'] == [0]
    assert digest_tree(root) == before


def test_raw_opt_in_retains_weak_view_instead_of_deleting_it(tmp_path):
    root = raw_scan(tmp_path, count=2)
    before = digest_tree(root)
    result = prepare_scan(root, tmp_path / 'prepared', policy=POLICY_V2,
                          critical_frame_protection=True, uv_unwrap=True)
    assert result.metadata['selectedIndices'] == [0, 1]
    assert result.metadata['criticalFrameProtection']['candidateFrameCount'] == 2
    assert result.metadata['criticalFrameProtection']['requestedProtectedIndices'] == [0, 1]
    assert result.metadata['criticalFrameProtection']['protectedIndices'] == [0, 1]
    assert result.metadata['processedPixelCount'] == 2 * 1920 * 1440
    assert digest_tree(root) == before


def test_risk_ranking_is_rejected_first_then_sharpness_then_source_order(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from processing_pipeline.critical_frame_protection import assess_candidates
    from processing_pipeline import native_quality
    from PIL import Image
    paths = []
    for ordinal in range(11):
        path = tmp_path / f'{ordinal}.png'
        Image.new('L', (12, 8), ordinal).save(path)
        paths.append(path)
    sharpness = [50, 1, 1, 30, 20, 10, 11, 12, 13, 14, 100]
    rejected = {0, 3, 4}
    def quality(gray):
        ordinal = int(gray[0, 0])
        return SimpleNamespace(accepted=ordinal not in rejected, rejection_reason=6 if ordinal in rejected else 0,
                               laplacian_variance=sharpness[ordinal], gray_standard_deviation=30)
    monkeypatch.setattr(native_quality, 'assess_gray', quality)
    result = assess_candidates(paths)
    assert result['candidateFrameCount'] == 10
    assert result['protectedIndices'] == [0, 1, 2, 3, 4, 5, 6, 7]


def test_raw_risk_assessment_rejects_unreadable_pixels(tmp_path):
    from processing_pipeline.critical_frame_protection import assess_candidates
    from PIL import Image
    path = tmp_path / 'tiny.png'
    Image.new('L', (1, 1), 120).save(path)
    with pytest.raises(ValueError, match='unreadable'):
        assess_candidates([path])


def test_authoritative_dedup_reports_removed_requested_protection(tmp_path):
    import numpy as np
    from PIL import Image
    root = raw_scan(tmp_path, count=2, size=(320, 240))
    pixels = np.random.default_rng(617).integers(0, 256, (240, 320), dtype=np.uint8)
    for ordinal in range(2):
        Image.fromarray(pixels).save(root / f'images/{ordinal}.jpg')
    path = root / 'manifest.json'
    manifest = json.loads(path.read_text())
    manifest['frames'][1]['transform'] = manifest['frames'][0]['transform']
    manifest['clientPreparation'] = client_metadata([(320, 240)] * 2, [1])
    path.write_text(json.dumps(manifest))
    before = digest_tree(root)
    prepared = prepare_scan(root, tmp_path / 'prepared', policy=POLICY_V2, uv_unwrap=True)
    report = prepared.metadata['criticalFrameProtection']
    assert prepared.metadata['selectedIndices'] == [0]
    assert report['requestedProtectedIndices'] == [1]
    assert report['protectedIndices'] == []
    assert report['deduplicatedProtectedIndices'] == [1]
    assert digest_tree(root) == before
