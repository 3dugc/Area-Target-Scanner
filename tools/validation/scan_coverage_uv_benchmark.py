"""Isolated local capacity measurement; synthetic geometry, no deployment claim."""
import json
import resource
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from processing_pipeline import uv_unwrap as uv


def run(mode, frame_count):
    if mode == "legacy":
        from tests.test_uv_frame_calibration import _legacy_assign_frames
        uv._vectorized_assign_frames = _legacy_assign_frames

    with tempfile.TemporaryDirectory(prefix="uv-capacity-") as directory:
        vertices, faces, coordinates, frames = [], [], [], []
        width, height = 640, 480
        intrinsics = dict(fx=320, fy=320, cx=320, cy=240, width=width, height=height)
        # One fixed 50k-face tessellated mesh covers 500 distinct camera positions.
        # 80/100 frame modes use only their first views on that same mesh.
        for zone in range(500):
            start = len(vertices)
            column, row = zone % 25, zone // 25
            for y in range(11):
                for x in range(6):
                    vertices.append([4. * zone - .25 + x * .1, -.25 + y * .05, -1.])
                    coordinates.append([(column + .1 + .8 * x / 5) / 25,
                                        (row + .1 + .8 * y / 10) / 20])
            for y in range(10):
                for x in range(5):
                    corner = start + y * 6 + x
                    faces.extend([[corner, corner + 1, corner + 6],
                                  [corner + 7, corner + 6, corner + 1]])
            if zone < frame_count:
                name = f"view-{zone}.png"
                with Image.new("RGB", (width, height),
                               ((zone + 1) % 256, 125 + zone // 256, (249 - zone) % 256)) as image:
                    image.save(Path(directory) / name)
                pose = np.eye(4)
                pose[0, 3] = 4. * zone
                frames.append(dict(imageFile=name, transform=pose.flatten(order="F").tolist(),
                                   intrinsics=intrinsics))
        vertices = np.asarray(vertices, dtype=np.float32)
        coordinates = np.asarray(coordinates, dtype=np.float32)
        faces = np.asarray(faces, dtype=np.int32)
        phases, assignments_used, caches = {}, [], []
        original_assign = uv._vectorized_assign_frames
        original_cache = uv._DecodedImageCache

        def timed_assign(*args):
            start = time.perf_counter()
            result = original_assign(*args)
            phases["assignment_seconds"] = time.perf_counter() - start
            assignments_used.append(len(np.unique(result[result >= 0])))
            return result

        class MeasuredCache(original_cache):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                caches.append(self)

        def progress(_message, value=None):
            if value in (19, 20, 27) and value not in phases:
                phases[value] = time.perf_counter()

        uv._vectorized_assign_frames = timed_assign
        uv._DecodedImageCache = MeasuredCache
        start = time.perf_counter()
        atlas = uv.render_texture_atlas(vertices, coordinates, faces, directory, intrinsics,
                                        {"frames": frames}, on_progress=progress, atlas_size=512)
        end = time.perf_counter()
        cache = caches[0]
        result = dict(mode=mode, frame_count=frame_count, face_count=len(faces),
                      atlas_size=512, image_dimensions=[width, height],
                      preparation_seconds=phases[19] - start,
                      assignment_seconds=phases["assignment_seconds"],
                      raster_seconds=phases[27] - phases[20],
                      fill_and_output_seconds=end - phases[27], render_seconds=end - start,
                      peak_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 ** 2 if sys.platform == "darwin" else 1024),
                      cache_peak_mib=cache.peak_bytes / 1024 ** 2,
                      cache_loads=cache.load_count, cache_evictions=cache.eviction_count,
                      assigned_distinct_views=assignments_used[0],
                      output_distinct_colors=len(np.unique(atlas.reshape(-1, 3), axis=0)))
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("legacy", "bounded"))
    parser.add_argument("frame_count", type=int, choices=(80, 100, 500))
    args = parser.parse_args()
    run(args.mode, args.frame_count)
