"""
Property Test 8: PnP refinement 精度不低于 RANSAC

对任意一组 N ≥ 8 个 3D-2D 对应点（含噪声），solvePnPRansac 成功后用 inlier 点 +
RANSAC 初始值做 solvePnP(ITERATIVE) 精化，精化后的位姿重投影误差应 ≤ RANSAC 原始结果
的重投影误差。此规则同时适用于 ORB 和 AKAZE 的 PnP 结果。

Tag: Feature: cross-session-precision-boost, Property 8: PnP refinement 精度不低于 RANSAC

**Validates: Requirements 5.1, 5.3**
"""
from __future__ import annotations

import numpy as np
import cv2
from hypothesis import given, settings, HealthCheck, assume
from hypothesis import strategies as st


# === 相机内参（固定） ===
FX = FY = 500.0
CX = 320.0
CY = 240.0
K = np.array([[FX, 0, CX], [0, FY, CY], [0, 0, 1]], dtype=np.float64)


# === 辅助函数 ===

def _make_rotation(rx_deg, ry_deg, rz_deg):
    """用欧拉角（度）构造旋转矩阵 R = Rz @ Ry @ Rx"""
    rx, ry, rz = np.radians(rx_deg), np.radians(ry_deg), np.radians(rz_deg)
    Rx = np.array([
        [1, 0, 0],
        [0, np.cos(rx), -np.sin(rx)],
        [0, np.sin(rx), np.cos(rx)],
    ])
    Ry = np.array([
        [np.cos(ry), 0, np.sin(ry)],
        [0, 1, 0],
        [-np.sin(ry), 0, np.cos(ry)],
    ])
    Rz = np.array([
        [np.cos(rz), -np.sin(rz), 0],
        [np.sin(rz), np.cos(rz), 0],
        [0, 0, 1],
    ])
    return Rz @ Ry @ Rx


def _project_points(pts3d, R, t, K):
    """将 3D 点投影到 2D 图像平面。
    pts3d: (N, 3), R: (3, 3), t: (3,), K: (3, 3)
    返回 (N, 2) 的 2D 点
    """
    pts_cam = (R @ pts3d.T).T + t  # (N, 3)
    pts_proj = (K @ pts_cam.T).T   # (N, 3)
    return pts_proj[:, :2] / pts_proj[:, 2:3]


def _compute_reprojection_error(pts3d, pts2d, rvec, tvec, K):
    """计算重投影误差（每个点的欧氏距离均值）"""
    projected, _ = cv2.projectPoints(pts3d, rvec, tvec, K, None)
    projected = projected.reshape(-1, 2)
    diffs = projected - pts2d.reshape(-1, 2)
    return float(np.mean(np.sqrt(np.sum(diffs ** 2, axis=1))))


# === Hypothesis 策略 ===

@st.composite
def pnp_scenario_strategy(draw):
    """生成随机 PnP 场景：3D 点 + 已知位姿 → 投影 2D 点 + 噪声。

    策略：先生成位姿，再在相机视锥内生成 3D 点，确保投影一定在图像范围内，
    避免 assume() 过滤导致 hypothesis 健康检查失败。

    - 15-50 个 3D 点，z > 1.0（在相机前方）
    - 小旋转角度（< 30°）
    - 高斯噪声 sigma 1-3 像素
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 随机 3D 点数量
    n_points = draw(st.integers(min_value=15, max_value=50))

    # 随机旋转（小角度 < 30°）
    rx = draw(st.floats(min_value=-15.0, max_value=15.0, allow_nan=False, allow_infinity=False))
    ry = draw(st.floats(min_value=-15.0, max_value=15.0, allow_nan=False, allow_infinity=False))
    rz = draw(st.floats(min_value=-15.0, max_value=15.0, allow_nan=False, allow_infinity=False))
    R = _make_rotation(rx, ry, rz)

    # 随机平移（小值）
    tx = draw(st.floats(min_value=-0.3, max_value=0.3, allow_nan=False, allow_infinity=False))
    ty = draw(st.floats(min_value=-0.3, max_value=0.3, allow_nan=False, allow_infinity=False))
    tz = draw(st.floats(min_value=-0.2, max_value=0.2, allow_nan=False, allow_infinity=False))
    t = np.array([tx, ty, tz], dtype=np.float64)

    # 在相机坐标系下生成点，确保投影在图像范围内
    # 先生成 2D 像素坐标（留 margin 避免边界问题），再反投影到 3D
    margin = 50.0
    pts2d_target = np.zeros((n_points, 2), dtype=np.float64)
    pts2d_target[:, 0] = rng.uniform(margin, 640.0 - margin, n_points)
    pts2d_target[:, 1] = rng.uniform(margin, 480.0 - margin, n_points)

    # 随机深度 z_cam ∈ [3.0, 8.0]（相机坐标系下）
    z_cam = rng.uniform(3.0, 8.0, n_points)

    # 反投影到相机坐标系 3D 点
    pts_cam = np.zeros((n_points, 3), dtype=np.float64)
    pts_cam[:, 0] = (pts2d_target[:, 0] - CX) / FX * z_cam
    pts_cam[:, 1] = (pts2d_target[:, 1] - CY) / FY * z_cam
    pts_cam[:, 2] = z_cam

    # 从相机坐标系转换到世界坐标系：p_cam = R @ p_world + t → p_world = R^T @ (p_cam - t)
    R_inv = R.T
    pts3d = (R_inv @ (pts_cam - t).T).T

    # 投影到 2D（验证 round-trip）
    pts2d_clean = _project_points(pts3d, R, t, K)

    # 添加高斯噪声
    noise_sigma = draw(st.floats(min_value=1.0, max_value=3.0,
                                  allow_nan=False, allow_infinity=False))
    noise = rng.normal(0, noise_sigma, pts2d_clean.shape)
    pts2d_noisy = pts2d_clean + noise

    return pts3d, pts2d_noisy, R, t, noise_sigma


# === Property Test ===

class TestPnPRefinementProperty:
    """Property 8: PnP refinement 精度不低于 RANSAC

    Feature: cross-session-precision-boost, Property 8: PnP refinement 精度不低于 RANSAC

    **Validates: Requirements 5.1, 5.3**
    """

    @given(scenario=pnp_scenario_strategy())
    @settings(
        max_examples=100,
        deadline=30000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_refinement_not_worse_than_ransac(self, scenario):
        """RANSAC + iterative refinement 的重投影误差应 ≤ RANSAC-only。

        步骤：
        1. 用 solvePnPRansac 获取 RANSAC-only 结果
        2. 用 RANSAC inlier + 初始值做 solvePnP(ITERATIVE) 精化
        3. 比较两者的重投影误差（仅在 inlier 点上）
        4. 精化后误差应 ≤ RANSAC 误差（允许 5% 容差应对数值噪声）

        **Validates: Requirements 5.1, 5.3**
        """
        pts3d, pts2d_noisy, R_true, t_true, noise_sigma = scenario

        pts3d_f = pts3d.astype(np.float32)
        pts2d_f = pts2d_noisy.astype(np.float32)

        # Step 1: RANSAC-only PnP
        ok_ransac, rvec_ransac, tvec_ransac, inliers = cv2.solvePnPRansac(
            pts3d_f, pts2d_f, K.astype(np.float32), None,
            iterationsCount=300,
            reprojectionError=12.0,
            confidence=0.99,
        )

        # RANSAC 必须成功且有足够 inlier
        assume(ok_ransac)
        assume(inliers is not None and len(inliers) >= 8)

        inlier_idx = inliers.flatten()
        pts3d_inlier = pts3d_f[inlier_idx]
        pts2d_inlier = pts2d_f[inlier_idx]

        # 计算 RANSAC-only 在 inlier 点上的重投影误差
        ransac_error = _compute_reprojection_error(
            pts3d_inlier, pts2d_inlier, rvec_ransac, tvec_ransac, K)

        # Step 2: Iterative refinement（用 RANSAC inlier + 初始值）
        rvec_ref = rvec_ransac.copy()
        tvec_ref = tvec_ransac.copy()
        ok_ref, rvec_ref, tvec_ref = cv2.solvePnP(
            pts3d_inlier, pts2d_inlier, K.astype(np.float32), None,
            rvec=rvec_ref, tvec=tvec_ref,
            useExtrinsicGuess=True,
            flags=cv2.SOLVEPNP_ITERATIVE,
        )

        # 如果 refinement 失败，回退到 RANSAC 结果（这本身是合法行为）
        if not ok_ref:
            return  # refinement 失败时回退，不违反 property

        # 计算 refinement 后在 inlier 点上的重投影误差
        refined_error = _compute_reprojection_error(
            pts3d_inlier, pts2d_inlier, rvec_ref, tvec_ref, K)

        # Step 3: 验证 refinement 误差 ≤ RANSAC 误差（允许 5% 容差）
        # 容差处理数值噪声：refined_error <= ransac_error * 1.05
        tolerance = 1.05
        assert refined_error <= ransac_error * tolerance, (
            f"PnP refinement 精度退化: "
            f"refined_error={refined_error:.6f} > "
            f"ransac_error={ransac_error:.6f} * {tolerance} = "
            f"{ransac_error * tolerance:.6f}, "
            f"n_points={len(pts3d)}, n_inliers={len(inlier_idx)}, "
            f"noise_sigma={noise_sigma:.2f}"
        )
