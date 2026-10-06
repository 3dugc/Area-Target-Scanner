"""Distinct viewpoints survive conservative pose and visual duplicate removal."""
import numpy as np
import pytest
from PIL import Image

from processing_pipeline.frame_selection import select_distinct_frames


def scene(tmp_path, count=3, *, flat=False):
    pixels = np.random.default_rng(617).integers(0, 256, (240, 320), dtype=np.uint8)
    if flat:
        pixels[:] = 128
    frames = []
    for index in range(count):
        path = tmp_path / f'{index}.png'
        Image.fromarray(pixels).save(path)
        frames.append(dict(path=str(path), pose=np.eye(4), source_image_id=index, run=1))
    return frames


def test_real_duplicate_images_keep_stable_representative(tmp_path):
    frames = scene(tmp_path)
    indices, report = select_distinct_frames(frames)
    assert indices == [0]
    assert report['duplicateFrameCount'] == 2
    assert report['duplicateGroups'] == [{'representativeIndex': 0, 'duplicateIndices': [1, 2]}]


@pytest.mark.parametrize('difference', ['position', 'rotation', 'run', 'appearance'])
def test_similar_images_need_all_three_duplicate_conditions(tmp_path, difference):
    frames = scene(tmp_path, 2)
    if difference == 'position':
        frames[1]['pose'][0, 3] = 2
    elif difference == 'rotation':
        frames[1]['pose'][:3, :3] = [[0, 0, 1], [0, 1, 0], [-1, 0, 0]]
    elif difference == 'run':
        frames[1]['run'] = 2
    else:
        Image.fromarray(np.random.default_rng(719).integers(0, 256, (240, 320), dtype=np.uint8)).save(frames[1]['path'])
    indices, report = select_distinct_frames(frames)
    assert indices == [0, 1]
    assert report['duplicateFrameCount'] == 0


def test_unobservable_or_invalid_pose_frames_are_retained(tmp_path):
    frames = scene(tmp_path, flat=True)
    frames[2]['pose'] = np.diag([2., 1., 1., 1.])
    indices, report = select_distinct_frames(frames)
    assert indices == [0, 1, 2]
    assert report['potentialWeakIndices'] == [0, 1, 2]


def test_nearby_chain_does_not_merge_distinct_endpoints(tmp_path):
    frames = scene(tmp_path)
    frames[1]['pose'][0, 3] = .06
    frames[2]['pose'][0, 3] = .12
    assert select_distinct_frames(frames)[0] == [0, 2]


def test_blurred_duplicate_cannot_replace_clear_reference(tmp_path):
    import cv2
    frames = scene(tmp_path, 2)
    sharp = np.array(Image.open(frames[0]['path']))
    Image.fromarray(cv2.GaussianBlur(sharp, (3, 3), .5)).save(frames[0]['path'])
    indices, _ = select_distinct_frames(frames)
    assert 1 in indices


def test_damaged_image_fails_instead_of_silently_removing_a_view(tmp_path):
    frames = scene(tmp_path, 1)
    (tmp_path / '0.png').write_bytes(b'broken')
    with pytest.raises(ValueError, match='decode'):
        select_distinct_frames(frames)


def test_shared_central_texture_is_not_a_duplicate_of_a_changed_view(tmp_path):
    frames = scene(tmp_path, 2)
    generator = np.random.default_rng(617)
    original = generator.integers(0, 256, (240, 320), dtype=np.uint8)
    changed = generator.integers(0, 256, original.shape, dtype=np.uint8)
    changed[40:200, 50:270] = original[40:200, 50:270]
    Image.fromarray(changed).save(frames[1]['path'])
    assert select_distinct_frames(frames)[0] == [0, 1]


def test_shared_texture_cannot_hide_a_changed_low_texture_region(tmp_path):
    frames = scene(tmp_path, 2)
    texture = np.random.default_rng(617).integers(0, 256, (240, 320), dtype=np.uint8)
    patch = texture[20:220, 50:270]
    for frame, shade in zip(frames, [100, 150]):
        pixels = np.full((240, 320), shade, dtype=np.uint8)
        pixels[20:220, 50:270] = patch
        Image.fromarray(pixels).save(frame['path'])
    assert select_distinct_frames(frames)[0] == [0, 1]


def test_orb_response_ties_cannot_exceed_thumbnail_analysis_budget(tmp_path):
    from processing_pipeline.frame_selection import _analyze
    tile = np.random.default_rng(1).integers(0, 256, (5, 5), dtype=np.uint8)
    path = tmp_path / 'repeat.png'
    Image.fromarray(np.tile(tile, (48, 64))).save(path)
    signature = _analyze(path)
    assert len(signature.points) <= 500
    assert len(signature.descriptors) == len(signature.points)
