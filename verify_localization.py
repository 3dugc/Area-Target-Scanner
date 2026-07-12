#!/usr/bin/env python3
"""
验证 GLB 模型定位对齐。
模拟 native PnP → C++ flip → C# HandleTrackingResult 的完整链路，
用 Python + matplotlib 3D 可视化验证模型是否正确放置在扫描原点。

问题描述：识别的物体"乱飞"，没有定位到扫描场景原点。
"""
import sqlite3, struct, json, os
import numpy as np
import cv2
import trimesh
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

OUT_DIR = "data/localization_verify"
os.makedirs(OUT_DIR, exist_ok=True)

DB_PATH = "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db"
GLB_PATH = "unity_project/Assets/StreamingAssets/SLAMTestAssets/optimized.glb"
SCAN_DIR = "/tmp/scan_latest/scan_20260320_145246"

def load_features_db():
    """加载 features.db 的 keyframe poses 和 3D 特征点"""
    db = sqlite3.connect(DB_PATH)
    kfs = {}
    for kf_id, pose_bytes in db.execute("SELECT id, pose FROM keyframes"):
        pose = np.array([struct.unpack_from('d', pose_bytes, i*8)[0]
                         for i in range(16)]).reshape(4, 4)
        feats = db.execute(
            "SELECT x, y, x3d, y3d, z3d FROM features WHERE keyframe_id=?",
            (kf_id,)).fetchall()
        pts2d = np.array([(f[0], f[1]) for f in feats], dtype=np.float64)
        pts3d = np.array([(f[2], f[3], f[4]) for f in feats], dtype=np.float64)
        kfs[kf_id] = {"pose_c2w": pose, "pts2d": pts2d, "pts3d": pts3d}
    db.close()
    return kfs


def load_glb_mesh():
    """加载 GLB 模型的顶点"""
    scene = trimesh.load(GLB_PATH, process=False)
    for name, geom in scene.geometry.items():
        return geom.vertices, geom.faces
    return None, None

def load_scan_poses():
    """加载原始扫描的 camera poses"""
    with open(os.path.join(SCAN_DIR, "poses.json")) as f:
        data = json.load(f)
    poses = []
    for fr in data["frames"]:
        t = np.array(fr["transform"]).reshape(4, 4).T  # col-major → row-major
        poses.append(t)
    return poses

def load_intrinsics():
    with open(os.path.join(SCAN_DIR, "intrinsics.json")) as f:
        intr = json.load(f)
    return intr

def simulate_pnp(kf_data, K):
    """模拟 native C++ 的 PnP + flip 流程"""
    pts3d = kf_data["pts3d"]
    pts2d = kf_data["pts2d"]

    success, rvec, tvec, inliers = cv2.solvePnPRansac(
        pts3d.astype(np.float32), pts2d.astype(np.float32),
        K.astype(np.float32), None,
        iterationsCount=200, reprojectionError=10.0, confidence=0.99)

    if not success or inliers is None or len(inliers) < 6:
        return None, None

    R_cv, _ = cv2.Rodrigues(rvec)
    t_cv = tvec.flatten()

    # C++ flip: diag(1,-1,-1) — OpenCV → Unity/ARKit 坐标系
    flip = np.diag([1.0, -1.0, -1.0])
    R_unity = flip @ R_cv @ flip
    t_unity = flip @ t_cv

    # 组装 4x4 (row-major, 和 C# Matrix4x4 一致)
    pose_unity = np.eye(4)
    pose_unity[:3, :3] = R_unity
    pose_unity[:3, 3] = t_unity

    return pose_unity, len(inliers)


def simulate_csharp_handle(pose_unity, ar_camera_pose):
    """
    模拟 SLAMTestSceneManager.HandleTrackingResult 的坐标变换。
    
    C# 代码:
      scanOriginInCam = (pose.m03, pose.m13, pose.m23)  // t_unity
      scanOriginInAR = arCameraPose.MultiplyPoint3x4(scanOriginInCam)
      scanToAR = arCameraPose * pose_unity
    """
    # scanOriginInCam = translation column of pose_unity
    scan_origin_in_cam = pose_unity[:3, 3]

    # arCameraPose.MultiplyPoint3x4(scanOriginInCam)
    scan_origin_in_ar = (ar_camera_pose[:3, :3] @ scan_origin_in_cam
                         + ar_camera_pose[:3, 3])

    # scanToAR = arCameraPose * pose_unity
    scan_to_ar = ar_camera_pose @ pose_unity

    return scan_origin_in_ar, scan_to_ar


def verify_coordinate_chain():
    """完整验证坐标链路"""
    print("=" * 70)
    print("GLB 模型定位验证")
    print("=" * 70)

    # 1. 加载数据
    kfs = load_features_db()
    verts, faces = load_glb_mesh()
    scan_poses = load_scan_poses()
    intr = load_intrinsics()

    K = np.array([
        [intr["fx"], 0, intr["cx"]],
        [0, intr["fy"], intr["cy"]],
        [0, 0, 1]
    ], dtype=np.float64)

    print(f"\nGLB 模型: {len(verts)} 顶点, {len(faces)} 面")
    print(f"  bounds: [{verts.min(0)}] → [{verts.max(0)}]")
    print(f"  center: {verts.mean(0)}")
    print(f"\nFeature DB: {len(kfs)} keyframes")
    print(f"Scan poses: {len(scan_poses)} frames")
    print(f"Intrinsics: fx={intr['fx']:.1f} fy={intr['fy']:.1f}")

    # 2. 对每个 keyframe 做 PnP，模拟完整链路
    print("\n" + "=" * 70)
    print("PnP 模拟 (每个 keyframe)")
    print("=" * 70)

    results = []
    for kf_id in sorted(kfs.keys()):
        kf = kfs[kf_id]
        pose_unity, n_inliers = simulate_pnp(kf, K)
        if pose_unity is None:
            print(f"  KF{kf_id}: PnP FAILED")
            continue

        # 用对应的 scan pose 作为 "AR camera pose"
        # scan pose index ≈ kf_id (keyframe 从 frame 3 开始)
        scan_idx = min(kf_id, len(scan_poses) - 1)
        ar_cam_pose = scan_poses[scan_idx]

        origin_in_ar, scan_to_ar = simulate_csharp_handle(pose_unity, ar_cam_pose)

        # DB 里的 camera-to-world pose 的 translation = 相机在世界中的位置
        cam_pos_gt = kf["pose_c2w"][:3, 3]

        print(f"  KF{kf_id}: inliers={n_inliers}")
        print(f"    t_unity (scanOriginInCam) = {pose_unity[:3,3]}")
        print(f"    AR cam pos               = {ar_cam_pose[:3,3]}")
        print(f"    scanOriginInAR           = {origin_in_ar}")
        print(f"    GT cam pos (from DB)     = {cam_pos_gt}")

        results.append({
            "kf_id": kf_id,
            "pose_unity": pose_unity,
            "ar_cam_pose": ar_cam_pose,
            "origin_in_ar": origin_in_ar,
            "scan_to_ar": scan_to_ar,
            "cam_pos_gt": cam_pos_gt,
        })

    return verts, faces, results, kfs, scan_poses


def plot_verification(verts, faces, results, kfs, scan_poses):
    """生成 3D 可视化图"""

    fig = plt.figure(figsize=(20, 16))

    # ---- Plot 1: 模型 + 特征点 + keyframe 位置 (扫描坐标系) ----
    ax1 = fig.add_subplot(2, 2, 1, projection='3d')
    ax1.set_title("扫描坐标系: GLB模型 + 特征点 + 相机位置")

    # 模型顶点 (subsample)
    idx = np.random.choice(len(verts), min(5000, len(verts)), replace=False)
    ax1.scatter(verts[idx, 0], verts[idx, 2], verts[idx, 1],
                s=0.3, c='lightgray', alpha=0.3, label='GLB mesh')

    # 特征点
    all_pts3d = np.vstack([kfs[k]["pts3d"] for k in kfs])
    ax1.scatter(all_pts3d[:, 0], all_pts3d[:, 2], all_pts3d[:, 1],
                s=1, c='blue', alpha=0.5, label='Feature 3D pts')

    # Keyframe 相机位置
    for kf_id in sorted(kfs.keys()):
        pos = kfs[kf_id]["pose_c2w"][:3, 3]
        ax1.scatter(pos[0], pos[2], pos[1], s=50, c='red', marker='^')
        ax1.text(pos[0], pos[2], pos[1], f'KF{kf_id}', fontsize=6)

    # 原点
    ax1.scatter(0, 0, 0, s=200, c='green', marker='*', label='Origin (0,0,0)')

    ax1.set_xlabel('X')
    ax1.set_ylabel('Z')
    ax1.set_zlabel('Y')
    ax1.legend(fontsize=8)

    # ---- Plot 2: 定位结果 — scanOriginInAR 应该在哪里 ----
    ax2 = fig.add_subplot(2, 2, 2, projection='3d')
    ax2.set_title("AR世界: scanOriginInAR 位置 (应该稳定)")

    for r in results:
        o = r["origin_in_ar"]
        ax2.scatter(o[0], o[2], o[1], s=80, c='green', marker='o')
        ax2.text(o[0], o[2], o[1], f'KF{r["kf_id"]}', fontsize=7)

    # AR camera positions
    for r in results:
        cp = r["ar_cam_pose"][:3, 3]
        ax2.scatter(cp[0], cp[2], cp[1], s=30, c='red', marker='^')

    ax2.set_xlabel('X')
    ax2.set_ylabel('Z')
    ax2.set_zlabel('Y')

    # ---- Plot 3: 变换后的模型顶点 (用 scanToAR 变换) ----
    ax3 = fig.add_subplot(2, 2, 3, projection='3d')
    ax3.set_title("AR世界: GLB模型变换后位置 (用 KF3 的 scanToAR)")

    if results:
        r0 = results[0]
        scan_to_ar = r0["scan_to_ar"]
        # 变换模型顶点到 AR 世界
        verts_h = np.hstack([verts[idx], np.ones((len(idx), 1))])
        verts_ar = (scan_to_ar @ verts_h.T).T[:, :3]

        ax3.scatter(verts_ar[:, 0], verts_ar[:, 2], verts_ar[:, 1],
                    s=0.3, c='lightblue', alpha=0.3, label='GLB in AR')

        # AR camera
        cp = r0["ar_cam_pose"][:3, 3]
        ax3.scatter(cp[0], cp[2], cp[1], s=100, c='red', marker='^', label='AR Camera')

        # Origin cube
        o = r0["origin_in_ar"]
        ax3.scatter(o[0], o[2], o[1], s=200, c='green', marker='*', label='Origin cube')

    ax3.set_xlabel('X')
    ax3.set_ylabel('Z')
    ax3.set_zlabel('Y')
    ax3.legend(fontsize=8)

    # ---- Plot 4: 帧间 scanOriginInAR 漂移 ----
    ax4 = fig.add_subplot(2, 2, 4)
    ax4.set_title("scanOriginInAR 帧间漂移")

    if len(results) > 1:
        origins = np.array([r["origin_in_ar"] for r in results])
        kf_ids = [r["kf_id"] for r in results]
        ax4.plot(kf_ids, origins[:, 0], 'r-o', label='X', markersize=4)
        ax4.plot(kf_ids, origins[:, 1], 'g-o', label='Y', markersize=4)
        ax4.plot(kf_ids, origins[:, 2], 'b-o', label='Z', markersize=4)
        ax4.set_xlabel('Keyframe ID')
        ax4.set_ylabel('Position (m)')
        ax4.legend()
        ax4.grid(True, alpha=0.3)

        # 计算漂移统计
        mean_origin = origins.mean(axis=0)
        std_origin = origins.std(axis=0)
        max_drift = np.max(np.linalg.norm(origins - mean_origin, axis=1))
        ax4.set_title(f"scanOriginInAR 漂移\n"
                       f"mean={mean_origin}, std={std_origin}\n"
                       f"max_drift={max_drift:.4f}m")

    plt.tight_layout()
    out = os.path.join(OUT_DIR, "localization_verify.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"\nSaved: {out}")


def diagnose_issues(verts, results, kfs):
    """诊断定位问题"""
    print("\n" + "=" * 70)
    print("诊断结果")
    print("=" * 70)

    if not results:
        print("  没有成功的 PnP 结果!")
        return

    origins = np.array([r["origin_in_ar"] for r in results])
    mean_origin = origins.mean(axis=0)
    std_origin = origins.std(axis=0)
    max_drift = np.max(np.linalg.norm(origins - mean_origin, axis=1))

    print(f"\n1. scanOriginInAR 稳定性:")
    print(f"   mean = {mean_origin}")
    print(f"   std  = {std_origin}")
    print(f"   max_drift = {max_drift:.4f} m")

    if max_drift > 0.5:
        print("   ⚠️ 漂移过大! 原点位置不稳定")
    elif max_drift > 0.1:
        print("   ⚠️ 有一定漂移，可能导致物体抖动")
    else:
        print("   ✅ 原点位置稳定")

    # 检查 scanToAR 变换后模型是否在合理位置
    r0 = results[0]
    scan_to_ar = r0["scan_to_ar"]
    model_center = verts.mean(axis=0)
    model_center_h = np.append(model_center, 1.0)
    model_center_ar = (scan_to_ar @ model_center_h)[:3]
    cam_pos = r0["ar_cam_pose"][:3, 3]
    dist_to_cam = np.linalg.norm(model_center_ar - cam_pos)

    print(f"\n2. 模型位置 (用 KF{r0['kf_id']} 的 scanToAR):")
    print(f"   模型中心 (scan): {model_center}")
    print(f"   模型中心 (AR):   {model_center_ar}")
    print(f"   AR 相机位置:     {cam_pos}")
    print(f"   模型到相机距离:  {dist_to_cam:.2f} m")

    if dist_to_cam > 10:
        print("   ⚠️ 模型离相机太远! 可能是坐标变换有问题")
    elif dist_to_cam < 0.1:
        print("   ⚠️ 模型和相机重叠! 可能是变换方向反了")
    else:
        print(f"   ✅ 距离合理 ({dist_to_cam:.2f}m)")

    # 检查 flip 是否正确
    print(f"\n3. 坐标系 flip 验证:")
    pose_unity = r0["pose_unity"]
    R = pose_unity[:3, :3]
    det = np.linalg.det(R)
    print(f"   det(R_unity) = {det:.4f} (应该接近 +1.0)")
    if abs(det - 1.0) > 0.01:
        print("   ⚠️ 旋转矩阵行列式不为1! flip 可能有问题")
    else:
        print("   ✅ 旋转矩阵有效")

    # 检查 t_unity 的方向
    t_unity = pose_unity[:3, 3]
    print(f"   t_unity = {t_unity}")
    print(f"   |t_unity| = {np.linalg.norm(t_unity):.4f} m")

    # 关键检查：scanOriginInCam 的 Z 分量
    # 在 Unity/ARKit 坐标系中，相机前方是 -Z
    # 所以 scanOriginInCam.z 应该是负数（原点在相机前方）
    if t_unity[2] > 0:
        print(f"   ⚠️ t_unity.z > 0: 扫描原点在相机后方 (Unity 中 -Z 是前方)")
        print(f"      这可能导致物体出现在相机后面!")
    else:
        print(f"   ✅ t_unity.z < 0: 扫描原点在相机前方")

    # 检查 scanToAR 矩阵
    print(f"\n4. scanToAR 矩阵 (arCameraPose * pose_unity):")
    print(f"   {scan_to_ar}")
    det_s2a = np.linalg.det(scan_to_ar[:3, :3])
    print(f"   det(R) = {det_s2a:.4f}")

    # 最终建议
    print(f"\n" + "=" * 70)
    print("问题分析与建议")
    print("=" * 70)

    print("""
核心问题: C++ native 代码对 PnP 结果做了 OpenCV→Unity 坐标翻转:
  flip = diag(1, -1, -1)
  R' = flip * R_opencv * flip
  t' = flip * t_opencv

但是 features.db 里的 3D 点和 keyframe poses 已经是 ARKit 坐标系
(Y-up, 右手系)，不是 OpenCV 坐标系 (Y-down, Z-forward)。

所以 PnP 的输入 3D 点是 ARKit 坐标，但 PnP 输出的 [R|t] 是 OpenCV
相机坐标系 (Y-down)。flip 的目的是把 OpenCV 相机坐标转回 ARKit/Unity。

验证: 如果 flip 正确，那么:
  scanOriginInCam = t_unity 应该把扫描原点 (0,0,0) 正确映射到
  相机坐标系中的位置。

然后 C# 用 arCameraPose.MultiplyPoint3x4(scanOriginInCam) 把它
变换到 AR 世界坐标。

如果 arCameraPose 和 PnP 用的帧不同步，就会导致"乱飞"。
""")


def main():
    verts, faces, results, kfs, scan_poses = verify_coordinate_chain()
    plot_verification(verts, faces, results, kfs, scan_poses)
    diagnose_issues(verts, results, kfs)


if __name__ == "__main__":
    main()
