#!/usr/bin/env python3
"""
跨 Session 定位测试 — C++ Native Localizer 并行版

与 test_cross_session_native.py 功能完全一致，但使用 multiprocessing.Pool
并行执行 25 个组合（5×5 矩阵），4 个 worker 进程。

注意：ctypes CDLL 句柄不能跨进程共享，每个 worker 必须独立加载 .dylib。

输出: debug/round22_native_with_at/
"""
import ctypes, json, struct, os, sys, time
import numpy as np
import cv2
import sqlite3
import multiprocessing

# === Native library 路径（每个 worker 进程独立加载）===
DYLIB_PATH = os.path.join("native_visual_localizer", "build", "libvisual_localizer.dylib")

# === ctypes 结构体定义（每个进程都需要）===
class VLResult(ctypes.Structure):
    _fields_ = [
        ("state", ctypes.c_int),
        ("pose", ctypes.c_float * 16),
        ("confidence", ctypes.c_float),
        ("matched_features", ctypes.c_int),
    ]

class VLDebugInfo(ctypes.Structure):
    _fields_ = [
        ("orb_keypoints", ctypes.c_int),
        ("candidate_keyframes", ctypes.c_int),
        ("best_kf_id", ctypes.c_int),
        ("best_raw_matches", ctypes.c_int),
        ("best_good_matches", ctypes.c_int),
        ("best_inliers", ctypes.c_int),
        ("best_bow_sim", ctypes.c_float),
        ("best_inlier_ratio", ctypes.c_float),
        ("akaze_triggered", ctypes.c_int),
        ("akaze_keypoints", ctypes.c_int),
        ("akaze_best_inliers", ctypes.c_int),
        ("consistency_rejected", ctypes.c_int),
    ]


def _setup_lib(lib):
    """为 ctypes library 设置 C API 签名"""
    lib.vl_create.restype = ctypes.c_void_p
    lib.vl_create.argtypes = []
    lib.vl_destroy.restype = None
    lib.vl_destroy.argtypes = [ctypes.c_void_p]

    lib.vl_add_vocabulary_word.restype = ctypes.c_int
    lib.vl_add_vocabulary_word.argtypes = [
        ctypes.c_void_p, ctypes.c_int,
        ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_float
    ]
    lib.vl_add_keyframe.restype = ctypes.c_int
    lib.vl_add_keyframe.argtypes = [
        ctypes.c_void_p, ctypes.c_int,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int,
        ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)
    ]
    lib.vl_add_keyframe_akaze.restype = ctypes.c_int
    lib.vl_add_keyframe_akaze.argtypes = [
        ctypes.c_void_p, ctypes.c_int,
        ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)
    ]
    lib.vl_build_index.restype = ctypes.c_int
    lib.vl_build_index.argtypes = [ctypes.c_void_p]
    lib.vl_process_frame.restype = VLResult
    lib.vl_process_frame.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int,
        ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float,
        ctypes.c_int, ctypes.POINTER(ctypes.c_float)
    ]
    lib.vl_reset.restype = None
    lib.vl_reset.argtypes = [ctypes.c_void_p]
    lib.vl_get_debug_info.restype = None
    lib.vl_get_debug_info.argtypes = [ctypes.c_void_p, ctypes.POINTER(VLDebugInfo)]
    lib.vl_set_alignment_transform.restype = None
    lib.vl_set_alignment_transform.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float)]
    return lib


# === 数据集配置（与串行版一致）===
DATASETS = {
    "data1": {
        "scan_dir": "data/data1/scan_20260325_104732",
        "db_path": "data/data1/features.db",
        "region": "A",
    },
    "data2": {
        "scan_dir": "data/data2/scan_20260323_175533/scan_20260323_175533",
        "db_path": "data/data2/features.db",
        "region": "A",
    },
    "data3": {
        "scan_dir": "data/data3/scan_20260324_142133",
        "db_path": "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db",
        "region": "A",
    },
    "data4": {
        "scan_dir": "data/data4/scan_20260325_112038",
        "db_path": "data/data4/features.db",
        "region": "B",
    },
    "data5": {
        "scan_dir": "data/data5/scan_20260325_114342",
        "db_path": "data/data5/features.db",
        "region": "B",
    },
}

OUT_DIR = "debug/round22_native_with_at"
os.makedirs(OUT_DIR, exist_ok=True)


def load_scan_data(scan_dir):
    """加载扫描数据（内参 + 帧列表）"""
    intrinsics = json.load(open(os.path.join(scan_dir, "intrinsics.json")))
    poses_data = json.load(open(os.path.join(scan_dir, "poses.json")))
    frames = []
    for f in poses_data["frames"]:
        c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order='F')
        img_path = os.path.join(scan_dir, f["imageFile"])
        if not os.path.exists(img_path):
            continue
        if np.allclose(c2w, np.eye(4), atol=1e-6):
            continue
        frames.append({"index": f["index"], "c2w": c2w, "img_path": img_path})
    frames.sort(key=lambda x: x["index"])
    return intrinsics, frames


def load_and_init_native(lib, db_path, load_akaze=True):
    """从 features.db 加载数据到 native localizer，返回 handle。
    注意：lib 必须是当前进程内加载的 ctypes.CDLL 实例。"""
    handle = lib.vl_create()
    db = sqlite3.connect(db_path)

    # 加载 vocabulary
    vocab_rows = db.execute(
        "SELECT word_id, descriptor, idf_weight FROM vocabulary ORDER BY word_id"
    ).fetchall()
    for word_id, desc_blob, idf_weight in vocab_rows:
        desc = np.frombuffer(desc_blob, dtype=np.uint8).copy()
        lib.vl_add_vocabulary_word(
            handle, word_id,
            desc.ctypes.data_as(ctypes.POINTER(ctypes.c_ubyte)),
            len(desc), float(idf_weight))

    # 加载 keyframes (ORB)
    kf_rows = db.execute("SELECT id, pose FROM keyframes ORDER BY id").fetchall()
    for kf_id, pose_blob in kf_rows:
        pose = np.array(
            [struct.unpack_from("d", pose_blob, i * 8)[0] for i in range(16)],
            dtype=np.float32).reshape(4, 4)
        features = db.execute(
            "SELECT x, y, x3d, y3d, z3d, descriptor FROM features WHERE keyframe_id=?",
            (kf_id,)).fetchall()
        if not features:
            continue
        pts2d = np.array([(f[0], f[1]) for f in features], dtype=np.float32).flatten()
        pts3d = np.array([(f[2], f[3], f[4]) for f in features], dtype=np.float32).flatten()
        descs = np.array([np.frombuffer(f[5], dtype=np.uint8) for f in features], dtype=np.uint8)
        desc_flat = descs.flatten()

        lib.vl_add_keyframe(
            handle, kf_id,
            pose.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
            desc_flat.ctypes.data_as(ctypes.POINTER(ctypes.c_ubyte)),
            len(features),
            pts3d.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
            pts2d.ctypes.data_as(ctypes.POINTER(ctypes.c_float)))

    # 加载 AKAZE 数据（如果有）
    if load_akaze:
        has_akaze = db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='akaze_features'"
        ).fetchone() is not None
        if has_akaze:
            for kf_id, _ in kf_rows:
                akaze_rows = db.execute(
                    "SELECT x, y, x3d, y3d, z3d, descriptor FROM akaze_features WHERE keyframe_id=?",
                    (kf_id,)).fetchall()
                if not akaze_rows:
                    continue
                akaze_pts2d = np.array([(f[0], f[1]) for f in akaze_rows], dtype=np.float32).flatten()
                akaze_pts3d = np.array([(f[2], f[3], f[4]) for f in akaze_rows], dtype=np.float32).flatten()
                akaze_descs = np.array([np.frombuffer(f[5], dtype=np.uint8) for f in akaze_rows], dtype=np.uint8)
                desc_len = akaze_descs.shape[1] if akaze_descs.ndim == 2 else 61
                akaze_flat = akaze_descs.flatten()

                lib.vl_add_keyframe_akaze(
                    handle, kf_id,
                    akaze_flat.ctypes.data_as(ctypes.POINTER(ctypes.c_ubyte)),
                    len(akaze_rows), desc_len,
                    akaze_pts3d.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
                    akaze_pts2d.ctypes.data_as(ctypes.POINTER(ctypes.c_float)))

    db.close()
    lib.vl_build_index(handle)
    return handle


def run_native_localization(lib, handle, frames, intrinsics):
    """用 C++ native localizer 跑定位，返回结果列表。
    numpy 数组（w2c_native, c2w）转为 list 以便跨进程序列化。"""
    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]

    results = []
    for frame in frames:
        img = cv2.imread(frame["img_path"])
        if img is None:
            results.append({"frame": frame["index"], "status": "img_error"})
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        h, w = gray.shape

        result = lib.vl_process_frame(
            handle,
            gray.ctypes.data_as(ctypes.POINTER(ctypes.c_ubyte)),
            w, h, fx, fy, cx, cy,
            0, None)

        # 获取 debug info
        debug = VLDebugInfo()
        lib.vl_get_debug_info(handle, ctypes.byref(debug))

        if result.state == 1:  # TRACKING
            w2c = np.array(list(result.pose), dtype=np.float64).reshape(4, 4)
            c2w = frame["c2w"]
            s2a = c2w @ w2c
            s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
            R_s2a = s2a[:3, :3]
            rot_err = float(np.degrees(np.arccos(np.clip((np.trace(R_s2a) - 1) / 2, -1, 1))))
            method = "akaze_fallback" if debug.akaze_triggered else "orb"
            results.append({
                "frame": frame["index"], "status": "ok", "method": method,
                "n_inliers": result.matched_features,
                "confidence": result.confidence,
                "s2a_err": s2a_err, "rot_err": rot_err,
                "akaze_triggered": debug.akaze_triggered,
                # numpy → list 以便 pickle 序列化
                "w2c_native": w2c.tolist(),
                "c2w": c2w.tolist(),
            })
        else:
            results.append({
                "frame": frame["index"], "status": "lost",
                "akaze_triggered": debug.akaze_triggered,
                "consistency_rejected": debug.consistency_rejected,
            })
    return results


def run_one_combination(args):
    """
    单个组合的完整工作函数（在 worker 进程中执行）。

    每个 worker 独立加载 .dylib，创建 native localizer，跑定位，返回结果。
    numpy 数组已转为 list，可安全跨进程传输。

    Args:
        args: (query_name, db_name, scan_data_for_query, db_path, load_akaze)
              scan_data_for_query = {"intrinsics": dict, "frames": list of dicts}
              frames 中的 c2w 已转为 list

    Returns:
        (label, results) — results 中 w2c_native/c2w 为 list 格式
    """
    query_name, db_name, scan_data_for_query, db_path, load_akaze = args
    label = f"{query_name}→{db_name}"

    try:
        # 每个 worker 进程独立加载 dylib
        worker_lib = ctypes.CDLL(DYLIB_PATH)
        _setup_lib(worker_lib)

        intrinsics = scan_data_for_query["intrinsics"]
        # 恢复 frames 中的 c2w 为 numpy array
        frames = []
        for f in scan_data_for_query["frames"]:
            frames.append({
                "index": f["index"],
                "c2w": np.array(f["c2w"], dtype=np.float64),
                "img_path": f["img_path"],
            })

        # 加载 DB 并初始化 native localizer
        handle = load_and_init_native(worker_lib, db_path, load_akaze=load_akaze)
        results = run_native_localization(worker_lib, handle, frames, intrinsics)
        worker_lib.vl_destroy(handle)

        return (label, results, None)

    except Exception as e:
        import traceback
        return (label, [], traceback.format_exc())


def summarize(results, label):
    """汇总结果（含对齐后精度）"""
    total = len(results)
    ok = [r for r in results if r["status"] in ("ok", "ok_rescued")]
    n_ok = len(ok)
    n_orb = len([r for r in ok if r.get("method") == "orb"])
    n_akaze = len([r for r in ok if r.get("method") == "akaze_fallback"])
    n_rescued = len([r for r in results if r["status"] == "ok_rescued"])
    n_failed = total - n_ok
    rate = n_ok / total if total > 0 else 0
    mean_err = np.mean([r["s2a_err"] for r in ok]) if ok else float("nan")
    mean_rot = np.mean([r["rot_err"] for r in ok]) if ok else float("nan")

    has_aligned = ok and ok[0].get("s2a_err_aligned") is not None
    mean_err_aligned = np.mean([r["s2a_err_aligned"] for r in ok]) if has_aligned else float("nan")

    aligned_info = f" | aligned_s2a={mean_err_aligned:.4f}" if has_aligned else ""
    method_info = f" (orb={n_orb}, akaze={n_akaze}, rescued={n_rescued})"
    print(f"  {label}: {n_ok}/{total} ({rate:.1%}){method_info} | "
          f"s2a_err={mean_err:.4f}{aligned_info} | rot={mean_rot:.1f}°")

    summary = {
        "label": label, "total": total, "ok": n_ok, "rate": rate,
        "n_orb": n_orb, "n_akaze": n_akaze, "n_rescued": n_rescued, "n_failed": n_failed,
        "mean_s2a_err": float(mean_err) if ok else None,
        "mean_rot_err": float(mean_rot) if ok else None,
    }
    if has_aligned:
        summary["mean_s2a_err_aligned"] = float(mean_err_aligned)
    return summary


def main():
    print("=" * 70)
    print("跨 Session 定位测试 — C++ Native Localizer（并行版，4 workers）")
    print("=" * 70)

    if not os.path.exists(DYLIB_PATH):
        print(f"❌ {DYLIB_PATH} 不存在，请先编译")
        sys.exit(1)

    t0 = time.time()

    # 加载扫描数据（主进程）
    scan_data = {}
    for name, cfg in DATASETS.items():
        if os.path.exists(os.path.join(cfg["scan_dir"], "poses.json")):
            intrinsics, frames = load_scan_data(cfg["scan_dir"])
            scan_data[name] = (intrinsics, frames)
            print(f"  {name} scan: {len(frames)} 帧")

    # 准备并行任务参数
    # frames 中的 c2w (numpy) 转为 list 以便 pickle 序列化
    names = ["data1", "data2", "data3", "data4", "data5"]
    tasks = []
    for query_name in names:
        if query_name not in scan_data:
            continue
        intrinsics, frames = scan_data[query_name]
        # 序列化友好的 scan_data
        serializable_frames = []
        for f in frames:
            serializable_frames.append({
                "index": f["index"],
                "c2w": f["c2w"].tolist(),
                "img_path": f["img_path"],
            })
        scan_data_serializable = {
            "intrinsics": intrinsics,
            "frames": serializable_frames,
        }

        for db_name in names:
            cfg = DATASETS[db_name]
            if not os.path.exists(cfg["db_path"]):
                continue
            tasks.append((query_name, db_name, scan_data_serializable,
                          cfg["db_path"], True))

    print(f"\n共 {len(tasks)} 个组合，使用 4 个 worker 进程并行执行...")
    print("-" * 70)

    # 并行执行
    raw_results = {}  # label -> results (w2c_native/c2w 为 list)
    completed = 0

    with multiprocessing.Pool(processes=4) as pool:
        for label, results, error in pool.imap_unordered(run_one_combination, tasks):
            completed += 1
            if error:
                print(f"  [{completed}/{len(tasks)}] ❌ {label}: 异常\n{error}")
            else:
                n_ok = len([r for r in results if r["status"] == "ok"])
                print(f"  [{completed}/{len(tasks)}] ✅ {label}: "
                      f"{n_ok}/{len(results)} 帧成功")
                raw_results[label] = results

    t_parallel = time.time() - t0
    print(f"\n并行定位完成，耗时 {t_parallel:.1f}s")

    # === 后处理（主进程）：一致性过滤 + AT 对齐 + 离群帧救回 ===
    print("\n后处理：一致性过滤 + AT 对齐 + 离群帧救回")
    print("-" * 70)

    from test_cross_session_matrix import compute_alignment_transform, rescue_outlier_frames

    all_results = {}
    for label, results in raw_results.items():
        # 恢复 numpy 数组
        for r in results:
            if "w2c_native" in r and isinstance(r["w2c_native"], list):
                r["w2c_native"] = np.array(r["w2c_native"], dtype=np.float64)
            if "c2w" in r and isinstance(r["c2w"], list):
                r["c2w"] = np.array(r["c2w"], dtype=np.float64)

        # 多帧一致性过滤
        ok_frames = [r for r in results if r["status"] == "ok"]
        if len(ok_frames) >= 3:
            s2a_errs = [r["s2a_err"] for r in ok_frames]
            median_err = np.median(s2a_errs)
            mad = np.median([abs(e - median_err) for e in s2a_errs])
            outlier_thresh = median_err + 3.0 * max(mad, 0.1)
            for r in ok_frames:
                if r["s2a_err"] > outlier_thresh:
                    r["status"] = "pnp_outlier"

        # 坐标系对齐（AT）
        ok_frames = [r for r in results if r["status"] == "ok"]
        if ok_frames:
            s2a_matrices = [r["c2w"] @ r["w2c_native"] for r in ok_frames]
            AT = compute_alignment_transform(s2a_matrices)
            for r in ok_frames:
                s2a_aligned = AT @ r["c2w"] @ r["w2c_native"]
                r["s2a_err_aligned"] = float(np.linalg.norm(s2a_aligned - np.eye(4)))
                R_aligned = s2a_aligned[:3, :3]
                r["rot_err_aligned"] = float(np.degrees(np.arccos(
                    np.clip((np.trace(R_aligned) - 1) / 2, -1, 1))))

            # 离群帧救回
            AT, rescued_count = rescue_outlier_frames(results, AT)

        # 清理 numpy 对象
        for r in results:
            r.pop("w2c_native", None)
            r.pop("c2w", None)

        summary = summarize(results, label)
        all_results[label] = summary

    # 成功率矩阵
    print("\n" + "=" * 70)
    print("成功率矩阵 (C++ Native 并行版)")
    print("=" * 70)
    header = f"{'query↓ db→':>12s}"
    for db_name in names:
        header += f" {db_name:>10s}"
    print(header)
    for query_name in names:
        row = f"{query_name:>12s}"
        for db_name in names:
            label = f"{query_name}→{db_name}"
            if label in all_results:
                rate = all_results[label]["rate"]
                row += f" {rate:>9.1%}"
            else:
                row += f" {'N/A':>10s}"
        print(row)

    # 区域分析
    same_session, same_region, diff_region = [], [], []
    for label, s in all_results.items():
        q, d = label.split("→")
        if q == d:
            same_session.append(s)
        elif DATASETS[q]["region"] == DATASETS[d]["region"]:
            same_region.append(s)
        else:
            diff_region.append(s)

    print(f"\n区域分析:")
    if same_session:
        print(f"  同 session: {np.mean([s['rate'] for s in same_session]):.1%}")
    if same_region:
        print(f"  同区域跨 session: {np.mean([s['rate'] for s in same_region]):.1%}")
    if diff_region:
        print(f"  跨区域: {np.mean([s['rate'] for s in diff_region]):.1%}")

    # JSON 报告
    elapsed = time.time() - t0
    report = os.path.join(OUT_DIR, "native_matrix.json")
    with open(report, "w") as f:
        json.dump({
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "elapsed_s": elapsed,
            "parallel_elapsed_s": t_parallel,
            "engine": "C++ native (libvisual_localizer.dylib) — parallel 4 workers",
            "results": all_results,
        }, f, indent=2, ensure_ascii=False)
    print(f"\n报告: {report}")
    print(f"总耗时: {elapsed:.1f}s（并行定位: {t_parallel:.1f}s）")


if __name__ == "__main__":
    main()
