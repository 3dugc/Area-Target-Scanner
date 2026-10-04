"""UV rendering must retain bounded decoded frames and preserve global hole filling."""
import gc
import hashlib
import weakref

import numpy as np
from PIL import Image

from processing_pipeline import uv_unwrap as uv


CACHE_BUDGET = 64 * 1024 * 1024


def _intrinsics(width, height):
    return dict(fx=width / 2, fy=width / 2, cx=width / 2, cy=height / 2,
                width=width, height=height)


def _scene(tmp_path, count=1, size=(64, 48)):
    """Each separated camera sees exactly one triangle and its distinct image."""
    width, height = size
    frames, vertices, faces, uvs = [], [], [], []
    columns = min(count, 11)
    rows = (count + columns - 1) // columns
    for index in range(count):
        x = 4 * index
        name = f"frame-{index}.png"
        Image.new("RGB", size, (index + 1, 125, 249 - index)).save(tmp_path / name)
        transform = np.eye(4)
        transform[0, 3] = x
        frames.append(dict(imageFile=name, transform=transform.flatten(order="F").tolist(),
                           intrinsics=_intrinsics(width, height)))
        start = len(vertices)
        vertices.extend([[x - .25, -.2, -1], [x + .25, -.2, -1], [x - .25, .2, -1]])
        faces.append([start, start + 1, start + 2])
        col, row = index % columns, index // columns
        left, right = (col + .05) / columns, (col + .95) / columns
        bottom, top = (row + .05) / rows, (row + .95) / rows
        uvs.extend([[left, bottom], [right, bottom], [left, top]])
    return (np.array(vertices), np.array(uvs), np.array(faces), str(tmp_path),
            _intrinsics(width, height), {"frames": frames})


def test_renderer_computes_global_nearest_indices_only_once(tmp_path, monkeypatch):
    scene = _scene(tmp_path)
    actual_edt = uv.distance_transform_edt
    calls = []

    def measure_edt(mask, **kwargs):
        calls.append(kwargs)
        return actual_edt(mask, **kwargs)

    monkeypatch.setattr(uv, "distance_transform_edt", measure_edt)
    result = uv.render_texture_atlas(*scene, atlas_size=32)
    np.testing.assert_array_equal(result, np.broadcast_to([1, 125, 249], result.shape))
    assert calls == [dict(return_distances=False, return_indices=True)]


def test_renderer_bounds_actual_77_view_decodes_and_releases_before_fill(tmp_path, monkeypatch):
    width, height = 640, 480
    scene = _scene(tmp_path, count=77, size=(width, height))
    actual_array = np.array
    arrays, decoded_colors, fill_live_bytes = [], set(), []
    peak_live_bytes = 0

    def live_bytes():
        return sum(array.nbytes for reference in arrays if (array := reference()) is not None)

    def measure_array(value, *args, **kwargs):
        nonlocal peak_live_bytes
        result = actual_array(value, *args, **kwargs)
        if isinstance(value, Image.Image):
            arrays.append(weakref.ref(result))
            decoded_colors.add(tuple(result[0, 0]))
            peak_live_bytes = max(peak_live_bytes, live_bytes())
        return result

    def progress(_message, value=None):
        if value == 27:
            gc.collect()
            fill_live_bytes.append(live_bytes())

    monkeypatch.setattr(uv.np, "array", measure_array)
    result = uv.render_texture_atlas(*scene, atlas_size=128, on_progress=progress)
    # All views must really be used; repeated three-view smoke cannot exercise the bug.
    assert len(decoded_colors) == 77
    assert len(np.unique(result.reshape(-1, 3), axis=0)) == 77
    # One previous loop-local image and one decoding image may transiently coexist with the LRU.
    assert peak_live_bytes <= CACHE_BUDGET + 2 * width * height * 3
    assert fill_live_bytes == [0]


def test_lru_accounts_mixed_sizes_refreshes_hits_and_skips_oversize(tmp_path, monkeypatch):
    frames = []
    for index, size in enumerate([(4, 2), (3, 3), (3, 2), (9, 4)]):
        name = f"mixed-{index}.png"
        Image.new("RGB", size, (13 + index, 25, 237)).save(tmp_path / name)
        frames.append(dict(imageFile=name))
    assert hasattr(uv, "_DecodedImageCache"), "Decoded frames require a byte-bounded LRU"
    cache = uv._DecodedImageCache(str(tmp_path), frames, max_bytes=64)
    actual_open = Image.open
    opened = []

    def record_open(*args, **kwargs):
        image = actual_open(*args, **kwargs)
        opened.append(image)
        return image

    monkeypatch.setattr(uv.Image, "open", record_open)
    first = cache.get(0)
    assert first.dtype == np.uint8
    np.testing.assert_array_equal(first, np.broadcast_to([13, 25, 237], first.shape))
    cache.get(1)
    assert cache.retained_bytes == 51
    assert cache.get(0) is first  # refresh 0, so the next eviction must remove 1
    third = cache.get(2)
    assert cache.retained_bytes == 42
    assert cache.get(0) is first
    assert cache.load_count == 3
    assert cache.get(2) is third
    cache.get(1)
    assert cache.load_count == 4
    assert cache.retained_bytes <= 64
    assert cache.peak_bytes <= 64
    assert cache.eviction_count == 2
    assert cache.get(3).nbytes == 108
    assert cache.retained_bytes == 0
    assert cache.get(3).nbytes == 108  # a frame larger than the budget is never retained
    assert cache.load_count == 6
    assert all(image.fp is None for image in opened)
    cache.clear()
    assert cache.retained_bytes == 0


def _legacy_normalize_and_fill(atlas, weight):
    """Independent whole-grid reference, including global nearest-neighbor ties."""
    result = atlas.copy()
    mask = weight > 0
    for channel in range(3):
        result[:, :, channel][mask] /= weight[mask]
    if mask.any() and (~mask).any():
        _, indices = uv.distance_transform_edt(~mask, return_distances=True, return_indices=True)
        for channel in range(3):
            layer = result[:, :, channel]
            layer[~mask] = layer[indices[0][~mask], indices[1][~mask]]
    return np.clip(result, 0, 255).astype(np.uint8)


def test_chunked_fill_matches_whole_grid_reference_across_row_boundaries(monkeypatch):
    random = np.random.default_rng(703)
    weight = np.zeros((267, 181), dtype=np.float32)
    weight[3::29, 5::23] = random.integers(1, 9, size=weight[3::29, 5::23].shape)
    # Sources on either side of a chunk boundary must compete globally.
    weight[127, 30] = 2
    weight[129, 160] = 3
    atlas = random.integers(0, 256, size=(*weight.shape, 3)).astype(np.float32) * weight[:, :, None]
    expected = _legacy_normalize_and_fill(atlas, weight)
    actual_edt, calls = uv.distance_transform_edt, []

    def measure_edt(mask, **kwargs):
        calls.append((mask.shape, kwargs))
        return actual_edt(mask, **kwargs)

    monkeypatch.setattr(uv, "distance_transform_edt", measure_edt)
    assert hasattr(uv, "_normalize_and_fill_atlas"), "Atlas fill must share global indices"
    filled = uv._normalize_and_fill_atlas(atlas, weight)
    np.testing.assert_array_equal(np.clip(atlas, 0, 255).astype(np.uint8), expected)
    assert filled == np.count_nonzero(weight) / weight.size * 100
    assert calls == [(weight.shape, dict(return_distances=False, return_indices=True))]


def test_empty_and_full_atlases_do_not_allocate_edt(monkeypatch):
    def forbidden(*_args, **_kwargs):
        raise AssertionError("Empty or full atlas does not need nearest indices")

    monkeypatch.setattr(uv, "distance_transform_edt", forbidden)
    assert hasattr(uv, "_normalize_and_fill_atlas"), "Atlas fill must bound temporary memory"
    empty = np.zeros((259, 31, 3), dtype=np.float32)
    assert uv._normalize_and_fill_atlas(empty, np.zeros((259, 31), dtype=np.float32)) == 0
    assert not empty.any()
    full = np.full((259, 31, 3), 174, dtype=np.float32)
    assert uv._normalize_and_fill_atlas(full, np.full((259, 31), 3, dtype=np.float32)) == 100
    np.testing.assert_array_equal(full, np.full_like(full, 58))


def test_quality_renderer_keeps_4096_resolution_and_one_global_fill(tmp_path, monkeypatch):
    scene = _scene(tmp_path)
    actual_edt, calls = uv.distance_transform_edt, []

    def measure_edt(mask, **kwargs):
        calls.append((mask.shape, kwargs))
        return actual_edt(mask, **kwargs)

    monkeypatch.setattr(uv, "distance_transform_edt", measure_edt)
    scene[1][:] *= .02  # exercise quality fill without a whole-atlas triangle temporary
    result = uv.render_texture_atlas(*scene, atlas_size=uv.QUALITY_ATLAS_SIZE)
    assert result.shape == (4096, 4096, 3)
    assert result.dtype == np.uint8
    for pixel in (result[0, 0], result[2048, 2048], result[-1, -1]):
        np.testing.assert_array_equal(pixel, [1, 125, 249])
    assert calls == [((4096, 4096), dict(return_distances=False, return_indices=True))]


def test_gradient_projection_and_overlapping_face_output_matches_baseline(tmp_path):
    scene = _scene(tmp_path, count=3, size=(64, 48))
    yy, xx = np.mgrid[:48, :64]
    for index in range(3):
        pixels = np.stack([(xx * (index + 1) + 17) % 256,
                           (yy * 3 + index * 59) % 256,
                           (xx + yy * 2 + index * 31) % 256], axis=2).astype(np.uint8)
        Image.fromarray(pixels).save(tmp_path / f"frame-{index}.png")
    # Overlap all three UV charts; frame choice and accumulation order stay unchanged.
    scene[1][:] = np.tile([[.1, .1], [.9, .1], [.1, .9]], (3, 1))
    result = uv.render_texture_atlas(*scene, atlas_size=263)
    # Frozen pre-fix renderer output, covering gradients, averaging and global nearest ties.
    assert hashlib.sha256(result.tobytes()).hexdigest() == "70622321edf441e89587223d4fbe28b877d40ccd57ec664327fde5b58450a5f4"
