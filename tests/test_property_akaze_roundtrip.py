"""
Property Test 5: AKAZE 特征数据库 round-trip

对任意包含 AKAZE 描述子的 KeyframeData 集合，通过 save_feature_database() 写入
features.db 后再通过 load_feature_database() 读取，每个 keyframe 的
akaze_descriptors、akaze_keypoints、akaze_points_3d 应与写入前完全一致。

Tag: Feature: cross-session-precision-boost, Property 5: AKAZE 特征数据库 round-trip

**Validates: Requirements 3.1**
"""
from __future__ import annotations

import os
import tempfile

import numpy as np
from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st

from processing_pipeline.feature_db import (
    load_feature_database,
    save_feature_database,
)
from processing_pipeline.models import FeatureDatabase, KeyframeData


# === Hypothesis 策略 ===

# AKAZE 描述子长度（bytes）
AKAZE_DESC_LEN = 61
# ORB 描述子长度（bytes）
ORB_DESC_LEN = 32


@st.composite
def akaze_keyframe_strategy(draw, image_id: int = 0):
    """生成包含随机 ORB + AKAZE 数据的 KeyframeData。

    - ORB 描述子: 32 bytes uint8（必需字段）
    - AKAZE 描述子: 61 bytes uint8
    - 2D 关键点: (x, y) 范围 [0, 1920) × [0, 1080)
    - 3D 点: (x, y, z) 范围 [-10, 10]
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # AKAZE 特征数量 [1, 50]
    n_akaze = draw(st.integers(min_value=1, max_value=50))
    # ORB 特征数量 [1, 50]（必需，因为 keyframe 需要 ORB 数据）
    n_orb = draw(st.integers(min_value=1, max_value=50))

    # ORB 数据
    orb_kps = [
        (float(rng.uniform(0, 1920)), float(rng.uniform(0, 1080)))
        for _ in range(n_orb)
    ]
    orb_pts3d = [
        (float(rng.uniform(-10, 10)), float(rng.uniform(-10, 10)), float(rng.uniform(-10, 10)))
        for _ in range(n_orb)
    ]
    orb_descs = rng.integers(0, 256, size=(n_orb, ORB_DESC_LEN), dtype=np.uint8)

    # AKAZE 数据
    akaze_kps = [
        (float(rng.uniform(0, 1920)), float(rng.uniform(0, 1080)))
        for _ in range(n_akaze)
    ]
    akaze_pts3d = [
        (float(rng.uniform(-10, 10)), float(rng.uniform(-10, 10)), float(rng.uniform(-10, 10)))
        for _ in range(n_akaze)
    ]
    akaze_descs = rng.integers(0, 256, size=(n_akaze, AKAZE_DESC_LEN), dtype=np.uint8)

    # 随机相机位姿
    pose = np.eye(4, dtype=np.float64)
    pose[:3, 3] = rng.uniform(-5, 5, size=3)

    return KeyframeData(
        image_id=image_id,
        keypoints=orb_kps,
        descriptors=orb_descs,
        points_3d=orb_pts3d,
        camera_pose=pose,
        akaze_descriptors=akaze_descs,
        akaze_keypoints=akaze_kps,
        akaze_points_3d=akaze_pts3d,
    )


@st.composite
def akaze_database_strategy(draw):
    """生成包含 1-5 个 keyframe 的 FeatureDatabase，每个都有 AKAZE 数据。"""
    n_keyframes = draw(st.integers(min_value=1, max_value=5))
    keyframes = []
    for i in range(n_keyframes):
        kf = draw(akaze_keyframe_strategy(image_id=i))
        keyframes.append(kf)
    return FeatureDatabase(
        keyframes=keyframes,
        global_descriptors=None,
        vocabulary=None,
    )


# === Property Test ===

class TestAkazeRoundTripProperty:
    """Property 5: AKAZE 特征数据库 round-trip

    Feature: cross-session-precision-boost, Property 5: AKAZE 特征数据库 round-trip

    **Validates: Requirements 3.1**
    """

    @given(db=akaze_database_strategy())
    @settings(
        max_examples=100,
        deadline=15000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_akaze_roundtrip_preserves_all_data(self, db: FeatureDatabase):
        """写入 features.db 后读取，AKAZE 数据应完全一致。

        验证每个 keyframe 的:
        - akaze_descriptors: 二进制描述子完全相等
        - akaze_keypoints: 2D 坐标精确匹配
        - akaze_points_3d: 3D 坐标精确匹配

        **Validates: Requirements 3.1**
        """
        # 使用 tempfile 创建唯一的 DB 路径（hypothesis 会复用 tmp_path）
        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = os.path.join(tmpdir, "features.db")

            # 写入
            save_feature_database(db, db_path)

            # 读取
            loaded = load_feature_database(db_path)

        # keyframe 数量一致
        assert len(loaded.keyframes) == len(db.keyframes), (
            f"Keyframe 数量不一致: 写入 {len(db.keyframes)}, 读取 {len(loaded.keyframes)}"
        )

        for orig_kf, loaded_kf in zip(db.keyframes, loaded.keyframes):
            # image_id 一致
            assert loaded_kf.image_id == orig_kf.image_id

            # --- AKAZE 描述子完全一致 ---
            assert loaded_kf.akaze_descriptors is not None, (
                f"Keyframe {orig_kf.image_id}: AKAZE 描述子加载后为 None"
            )
            np.testing.assert_array_equal(
                loaded_kf.akaze_descriptors,
                orig_kf.akaze_descriptors,
                err_msg=f"Keyframe {orig_kf.image_id}: AKAZE 描述子不一致",
            )
            # 验证描述子形状（N, 61）
            assert loaded_kf.akaze_descriptors.shape == orig_kf.akaze_descriptors.shape, (
                f"Keyframe {orig_kf.image_id}: AKAZE 描述子形状不一致 "
                f"{loaded_kf.akaze_descriptors.shape} vs {orig_kf.akaze_descriptors.shape}"
            )

            # --- AKAZE 2D 关键点精确匹配 ---
            assert loaded_kf.akaze_keypoints is not None, (
                f"Keyframe {orig_kf.image_id}: AKAZE keypoints 加载后为 None"
            )
            assert len(loaded_kf.akaze_keypoints) == len(orig_kf.akaze_keypoints), (
                f"Keyframe {orig_kf.image_id}: AKAZE keypoints 数量不一致"
            )
            for j, ((ox, oy), (lx, ly)) in enumerate(
                zip(orig_kf.akaze_keypoints, loaded_kf.akaze_keypoints)
            ):
                assert abs(lx - ox) < 1e-6, (
                    f"Keyframe {orig_kf.image_id}, AKAZE kp[{j}].x: {ox} vs {lx}"
                )
                assert abs(ly - oy) < 1e-6, (
                    f"Keyframe {orig_kf.image_id}, AKAZE kp[{j}].y: {oy} vs {ly}"
                )

            # --- AKAZE 3D 点精确匹配 ---
            assert loaded_kf.akaze_points_3d is not None, (
                f"Keyframe {orig_kf.image_id}: AKAZE points_3d 加载后为 None"
            )
            assert len(loaded_kf.akaze_points_3d) == len(orig_kf.akaze_points_3d), (
                f"Keyframe {orig_kf.image_id}: AKAZE points_3d 数量不一致"
            )
            for j, (op, lp) in enumerate(
                zip(orig_kf.akaze_points_3d, loaded_kf.akaze_points_3d)
            ):
                for dim, (a, b) in enumerate(zip(op, lp)):
                    assert abs(a - b) < 1e-6, (
                        f"Keyframe {orig_kf.image_id}, AKAZE pt3d[{j}][{dim}]: {a} vs {b}"
                    )

            # --- ORB 数据也应保持不变（AKAZE 不影响 ORB）---
            np.testing.assert_array_equal(
                loaded_kf.descriptors,
                orig_kf.descriptors,
                err_msg=f"Keyframe {orig_kf.image_id}: ORB 描述子被 AKAZE 影响",
            )
