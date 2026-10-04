"""Regression tests at archive extraction and camera metadata boundaries."""
import io
import json
import os
import stat
import zipfile

import pytest


def archive(entries):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as output:
        for name, body in entries:
            output.writestr(name, body)
    data.seek(0)
    return zipfile.ZipFile(data)


def test_zip_entry_count_is_bounded_before_any_extraction(tmp_path):
    from web_service.app import safe_extract
    with archive([(f'f{i}', b'') for i in range(10001)]) as data:
        with pytest.raises(ValueError, match='entries'):
            safe_extract(data, str(tmp_path))
    assert list(tmp_path.iterdir()) == []


def test_zip_symlink_entries_are_rejected(tmp_path):
    from web_service.app import safe_extract
    entry = zipfile.ZipInfo('outside')
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    with archive([(entry, b'/private/secret')]) as data:
        with pytest.raises(ValueError, match='regular'):
            safe_extract(data, str(tmp_path))


@pytest.mark.parametrize('name', ['/absolute', '../escape', 'a/../../escape', 'a\\..\\escape', 'a:b', 'a//b'])
def test_zip_paths_are_portable_and_contained(tmp_path, name):
    from web_service.app import safe_extract
    with archive([(name, b'bad')]) as data:
        with pytest.raises(ValueError):
            safe_extract(data, str(tmp_path))


def test_zip_duplicate_paths_are_rejected(tmp_path):
    from web_service.app import safe_extract
    with pytest.warns(UserWarning, match='Duplicate name'), archive([('same', b'one'), ('same', b'two')]) as data:
        with pytest.raises(ValueError, match='duplicate'):
            safe_extract(data, str(tmp_path))


@pytest.mark.parametrize('reference', ['../secret', '/private/secret', 'images/../../secret'])
def test_pipeline_rejects_outside_frame_reference(tmp_path, reference):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline
    for name in ('model.obj', 'texture.jpg', 'model.mtl'):
        (tmp_path / name).write_bytes(b'x')
    (tmp_path / 'poses.json').write_text(json.dumps({'frames': [{'imageFile': reference,
        'transform': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}]}))
    with pytest.raises(ValueError, match='inside'):
        OptimizedPipeline().validate_input(str(tmp_path))


def test_pipeline_metadata_size_is_bounded(tmp_path):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline
    for name in ('model.obj', 'texture.jpg', 'model.mtl'):
        (tmp_path / name).write_bytes(b'x')
    (tmp_path / 'poses.json').write_bytes(b' ' * (8 * 1024 * 1024 + 1))
    with pytest.raises(ValueError, match='metadata'):
        OptimizedPipeline().validate_input(str(tmp_path))


def test_pipeline_requires_regular_keyframe_file(tmp_path):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline
    for name in ('model.obj', 'texture.jpg', 'model.mtl'):
        (tmp_path / name).write_bytes(b'x')
    (tmp_path / 'images').mkdir()
    (tmp_path / 'poses.json').write_text(json.dumps({'frames': [{'imageFile': 'images/missing.jpg',
        'transform': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}]}))
    with pytest.raises(ValueError, match='regular'):
        OptimizedPipeline().validate_input(str(tmp_path))


def test_uv_camera_metadata_size_is_bounded_before_mesh_processing(tmp_path, monkeypatch):
    import processing_pipeline.uv_unwrap as uv
    (tmp_path / 'model.obj').write_text('v 0 0 0\n')
    (tmp_path / 'intrinsics.json').write_text('{}')
    (tmp_path / 'poses.json').write_bytes(b' ' * (8 * 1024 * 1024 + 1))
    monkeypatch.setattr(uv, 'parse_obj', lambda *_: pytest.fail('Unsafe metadata reached mesh processing'))
    with pytest.raises(ValueError, match='metadata'):
        uv.uv_unwrap_scan(str(tmp_path))


@pytest.mark.parametrize('name', ['model.obj', 'model.mtl', 'texture.jpg', 'poses.json', 'intrinsics.json'])
def test_pipeline_rejects_symlinked_scan_resource_outside_root(tmp_path, name):
    from processing_pipeline.optimized_pipeline import OptimizedPipeline
    scan = tmp_path / 'scan'; scan.mkdir()
    (scan / 'images').mkdir()
    (scan / 'images/f.jpg').write_bytes(b'x')
    for resource in ('model.obj', 'model.mtl', 'texture.jpg'):
        (scan / resource).write_bytes(b'x')
    pose = {'frames': [{'imageFile': 'images/f.jpg', 'transform': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}]}
    (scan / 'poses.json').write_text(json.dumps(pose))
    (scan / 'intrinsics.json').write_text('{}')
    external = tmp_path / 'external'
    external.write_bytes((scan / name).read_bytes())
    (scan / name).unlink()
    (scan / name).symlink_to(external)
    with pytest.raises(ValueError, match='inside'):
        OptimizedPipeline().validate_input(str(scan))
