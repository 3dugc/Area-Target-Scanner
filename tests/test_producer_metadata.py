"""Feature producer metadata must remain additive to the existing bundle format."""

import json
import sqlite3

import cv2
import numpy as np
import trimesh

from processing_pipeline.feature_db import load_feature_database
from processing_pipeline.models import FeatureDatabase, KeyframeData
from processing_pipeline.optimized_pipeline import OptimizedPipeline


def test_bundle_records_opencv_producer_without_changing_feature_bytes(tmp_path):
    mesh = trimesh.creation.box()
    glb_path = tmp_path / "source.glb"
    mesh.export(glb_path)
    orb = np.arange(64, dtype=np.uint8).reshape(2, 32)
    akaze = np.arange(122, dtype=np.uint8).reshape(2, 61)
    features = FeatureDatabase(
        keyframes=[KeyframeData(
            image_id=7,
            keypoints=[(10.0, 20.0), (30.0, 40.0)],
            descriptors=orb,
            points_3d=[(0.0, 0.0, -1.0), (1.0, 0.0, -1.0)],
            camera_pose=np.eye(4),
            akaze_descriptors=akaze,
            akaze_keypoints=[(11.0, 21.0), (31.0, 41.0)],
            akaze_points_3d=[(0.0, 0.0, -1.0), (1.0, 0.0, -1.0)],
        )],
        vocabulary=orb.copy(),
        global_descriptors=np.array([[0.6, 0.8]], dtype=np.float64),
    )
    output_dir = tmp_path / "bundle"

    OptimizedPipeline().export_asset_bundle(
        str(glb_path), mesh, features, str(output_dir)
    )

    manifest = json.loads((output_dir / "manifest.json").read_text())
    assert manifest.get("producer") == {"opencvVersion": cv2.__version__}
    assert manifest["version"] == "2.0"
    with sqlite3.connect(output_dir / "features.db") as database:
        assert database.execute("SELECT descriptor FROM features ORDER BY id").fetchall() == [
            (row.tobytes(),) for row in orb
        ]
        assert database.execute("SELECT descriptor FROM akaze_features ORDER BY id").fetchall() == [
            (row.tobytes(),) for row in akaze
        ]
        assert database.execute("SELECT pose FROM keyframes").fetchone()[0] == np.eye(4).tobytes()
        assert database.execute("SELECT global_descriptor FROM keyframes").fetchone()[0] == features.global_descriptors[0].tobytes()
        assert database.execute("SELECT descriptor FROM vocabulary ORDER BY word_id").fetchall() == [
            (row.tobytes(),) for row in orb
        ]
    loaded = load_feature_database(str(output_dir / "features.db"))
    np.testing.assert_array_equal(loaded.keyframes[0].descriptors, orb)
    np.testing.assert_array_equal(loaded.keyframes[0].akaze_descriptors, akaze)
