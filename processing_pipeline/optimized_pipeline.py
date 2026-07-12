"""Optimized 4-step processing pipeline for iOS textured model scans.

Replaces the 6-step ReconstructionPipeline with a streamlined flow:
  1. Input validation
  2. Model optimization (via 3D-Model-Optimizer service)
  3. Feature extraction (ORB + BoW)
  4. Asset bundling
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
from datetime import datetime, timezone

import numpy as np

from processing_pipeline.feature_db import save_feature_database
from processing_pipeline.models import FeatureDatabase, ScanInput
from processing_pipeline.optimizer_client import ModelOptimizerClient

FEATURE_PROFILE_OPTIONS = {
    "fast": {
        "extract_akaze": False,
        "orb_nfeatures": 1000,
        "bow_k": 500,
        "max_keyframes": 80,
        "use_minibatch_kmeans": True,
        "kmeans_n_init": 1,
        "kmeans_max_iter": 50,
        "kmeans_batch_size": 4096,
    },
    "quality": {
        "extract_akaze": True,
        "orb_nfeatures": 2000,
        "bow_k": 1000,
        "max_keyframes": None,
        "use_minibatch_kmeans": False,
        "kmeans_n_init": 3,
        "kmeans_max_iter": 300,
        "kmeans_batch_size": 4096,
    },
}


class OptimizedPipeline:
    """4-step pipeline that processes iOS scan data into an AR asset bundle.

    The pipeline expects a scan directory containing a textured OBJ model
    (model.obj + texture.jpg + model.mtl), camera poses (poses.json), and
    optionally camera intrinsics (intrinsics.json) with keyframe images.

    Args:
        optimizer_url: Base URL of the 3D-Model-Optimizer service.
        optimizer_preset: Optimization preset passed to the optimizer
            (e.g. ``"balanced"``).
    """

    def __init__(
        self,
        optimizer_url: str = "http://model_optimizer:3000",
        optimizer_preset: str = "balanced",
        processing_profile: str = "quality",
    ) -> None:
        self.optimizer_url = optimizer_url
        self.optimizer_preset = optimizer_preset
        self.processing_profile = (
            processing_profile
            if processing_profile in FEATURE_PROFILE_OPTIONS
            else "quality"
        )

    def validate_input(self, scan_dir: str) -> ScanInput:
        """Validate that *scan_dir* contains all required files and load poses.

        Raises:
            FileNotFoundError: If a required file is missing.
            ValueError: If poses.json contains no frames.
        """
        obj_path = os.path.join(scan_dir, "model.obj")
        texture_path = os.path.join(scan_dir, "texture.jpg")
        mtl_path = os.path.join(scan_dir, "model.mtl")
        poses_path = os.path.join(scan_dir, "poses.json")

        for p in [obj_path, texture_path, mtl_path, poses_path]:
            if not os.path.isfile(p):
                raise FileNotFoundError(f"必需文件缺失: {p}")

        with open(poses_path) as f:
            poses_data = json.load(f)
        frames = poses_data.get("frames", [])
        if not frames:
            raise ValueError("poses.json 不包含任何帧")

        images = []
        for frame in frames:
            image_path = os.path.join(scan_dir, frame["imageFile"])
            transform = np.array(
                frame["transform"], dtype=np.float64
            ).reshape(4, 4, order="F")
            images.append({"path": image_path, "pose": transform})

        intrinsics = None
        intrinsics_path = os.path.join(scan_dir, "intrinsics.json")
        if os.path.isfile(intrinsics_path):
            with open(intrinsics_path) as f:
                intrinsics = json.load(f)

        return ScanInput(
            obj_path=obj_path,
            texture_path=texture_path,
            mtl_path=mtl_path,
            images=images,
            intrinsics=intrinsics,
        )

    def optimize_model(self, scan_input: ScanInput, work_dir: str) -> str:
        """Send the OBJ model to the optimizer service and return the GLB path.

        Raises:
            RuntimeError: If the optimization fails or the result is empty.
        """
        client = ModelOptimizerClient(base_url=self.optimizer_url)
        # Disable Draco compression so that downstream trimesh / Open3D
        # can read the GLB vertices correctly for feature extraction and
        # bounding-box computation.
        task_id = client.optimize(
            obj_path=scan_input.obj_path,
            mtl_path=scan_input.mtl_path,
            texture_path=scan_input.texture_path,
            preset=self.optimizer_preset,
            options={"draco": {"enabled": False}},
        )
        final_status = client.wait_for_completion(task_id)
        if final_status != "completed":
            raise RuntimeError(f"模型优化失败: {final_status}")
        glb_path = os.path.join(work_dir, "optimized.glb")
        client.download(task_id, glb_path)
        if not os.path.isfile(glb_path) or os.path.getsize(glb_path) == 0:
            raise RuntimeError("下载的 GLB 文件为空")
        return glb_path
    @staticmethod
    def _trimesh_to_o3d(mesh_tri):
        """Convert a trimesh.Trimesh to an open3d.geometry.TriangleMesh.

        Handles the int64→int32 face conversion required by Open3D's
        Vector3iVector to avoid segfaults.
        """
        import open3d as o3d

        o3d_mesh = o3d.geometry.TriangleMesh()
        o3d_mesh.vertices = o3d.utility.Vector3dVector(
            np.asarray(mesh_tri.vertices, dtype=np.float64)
        )
        o3d_mesh.triangles = o3d.utility.Vector3iVector(
            np.asarray(mesh_tri.faces, dtype=np.int32)
        )
        return o3d_mesh

    def build_feature_database(
        self,
        mesh_tri,
        images: list[dict],
        intrinsics: dict | None = None,
    ) -> FeatureDatabase:
        """Build an ORB + BoW feature database from the trimesh mesh and keyframes.

        Args:
            mesh_tri: A trimesh.Trimesh object (already loaded and merged).
            images: List of keyframe image dicts with 'path' and 'pose'.
            intrinsics: Optional camera intrinsics dict.

        Raises:
            RuntimeError: If feature extraction fails.
        """
        from processing_pipeline.feature_extraction import build_feature_database

        # Convert trimesh mesh to Open3D TriangleMesh for ray-casting
        o3d_mesh = self._trimesh_to_o3d(mesh_tri)

        # Reuse existing ORB + ray-casting + BoW logic
        feature_options = FEATURE_PROFILE_OPTIONS[self.processing_profile]
        return build_feature_database(
            images,
            o3d_mesh,
            intrinsics,
            **feature_options,
        )

    def export_asset_bundle(
        self,
        glb_path: str,
        mesh_tri,
        features: FeatureDatabase,
        output_dir: str,
    ) -> None:
        """Package optimized.glb, features.db, and manifest.json into *output_dir*.

        Args:
            glb_path: Path to the optimized GLB file (copied to output).
            mesh_tri: A trimesh.Trimesh object for computing AABB bounds.
            features: The FeatureDatabase to serialize.
            output_dir: Directory to write the asset bundle into.
        """
        os.makedirs(output_dir, exist_ok=True)

        # 1. Copy GLB
        glb_dst = os.path.join(output_dir, "optimized.glb")
        shutil.copy2(glb_path, glb_dst)

        # 2. Save feature database
        db_path = os.path.join(output_dir, "features.db")
        save_feature_database(features, db_path)

        # 3. Compute AABB bounds from the already-loaded mesh
        bounds = mesh_tri.bounds  # [[min_x,min_y,min_z],[max_x,max_y,max_z]]

        # 4. Generate manifest.json
        manifest = {
            "version": "2.0",
            "meshFile": "optimized.glb",
            "featureDbFile": "features.db",
            "bounds": {
                "min": bounds[0].tolist(),
                "max": bounds[1].tolist(),
            },
            "keyframeCount": len(features.keyframes),
            "featureType": "ORB",
            "format": "glb",
            "optimizedWith": "3D-Model-Optimizer",
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }

        with open(os.path.join(output_dir, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)

    def run(self, scan_dir: str, output_dir: str) -> None:
        """Execute the full optimized pipeline.

        Steps:
            1. Validate input files and load poses/intrinsics.
            2. Optimize the OBJ model to GLB via 3D-Model-Optimizer.
            3. Extract ORB + BoW features from the GLB and keyframes.
            4. Bundle optimized.glb + features.db + manifest.json.

        Args:
            scan_dir: Path to the extracted scan directory.
            output_dir: Path to write the output asset bundle.

        Raises:
            FileNotFoundError: If required input files are missing.
            ValueError: If poses.json is malformed.
            RuntimeError: If model optimization or feature extraction fails.
        """
        import trimesh

        logger = logging.getLogger(__name__)
        work_dir = tempfile.mkdtemp(prefix="pipeline_")
        try:
            # Step 1
            logger.info("Step 1/4: 输入验证")
            scan_input = self.validate_input(scan_dir)

            # Step 2
            logger.info("Step 2/4: 模型优化")
            glb_path = self.optimize_model(scan_input, work_dir)

            # Load GLB once
            scene = trimesh.load(glb_path)
            if isinstance(scene, trimesh.Scene):
                mesh_tri = scene.to_geometry()
            else:
                mesh_tri = scene

            # Step 3
            logger.info("Step 3/4: 特征提取")
            features = self.build_feature_database(
                mesh_tri, scan_input.images, scan_input.intrinsics
            )

            # Step 4
            logger.info("Step 4/4: 资产打包")
            self.export_asset_bundle(glb_path, mesh_tri, features, output_dir)
        finally:
            shutil.rmtree(work_dir, ignore_errors=True)
