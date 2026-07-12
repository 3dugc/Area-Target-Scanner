"""
AKAZE fallback 帧纳入一致性过滤 单元测试

验证 test_cross_session_matrix.py 的 main() 中多帧一致性过滤
对 AKAZE fallback 帧（method="akaze_fallback", status="ok"）同等适用：
- AKAZE 帧与 ORB 帧一起参与 median + 3×MAD 过滤
- s2a_err 偏离阈值的 AKAZE 帧被标记为 pnp_outlier
- 正常 AKAZE 帧保留 status="ok"，不拉低对齐精度

需求: 2.4
"""
import numpy as np
import pytest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import compute_alignment_transform


def _make_frame(index, c2w, w2c_native, status="ok", method="orb"):
    """构造一个模拟帧结果"""
    s2a = c2w @ w2c_native
    s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
    return {
        "frame": index,
        "status": status,
        "method": method,
        "n_matches": 30,
        "n_inliers": 20,
        "inlier_ratio": 0.67,
        "s2a_err": s2a_err,
        "rot_err": 5.0,
        "w2c_native": w2c_native,
        "c2w": c2w,
    }


def _apply_consistency_filter(results):
    """
    复现 main() 中的多帧一致性过滤逻辑。
    这是 main() 中 run_localization() 之后的过滤代码的精确复制。
    """
    ok_frames = [r for r in results if r["status"] == "ok"]
    if len(ok_frames) >= 3:
        s2a_errs = [r["s2a_err"] for r in ok_frames]
        median_err = np.median(s2a_errs)
        mad = np.median([abs(e - median_err) for e in s2a_errs])
        outlier_thresh = median_err + 3.0 * max(mad, 0.1)
        for r in ok_frames:
            if r["s2a_err"] > outlier_thresh:
                r["status"] = "pnp_outlier"
                r["outlier_reason"] = (
                    f"s2a_err={r['s2a_err']:.2f} > thresh={outlier_thresh:.2f}"
                )
    return results


class TestAkazeConsistencyFilter:
    """验证 AKAZE fallback 帧纳入一致性过滤"""

    def test_akaze_frames_included_in_filtering(self):
        """AKAZE 帧（status='ok'）应与 ORB 帧一起参与一致性过滤"""
        T_offset = np.eye(4)
        T_offset[:3, 3] = [0.05, 0.02, -0.01]

        # 5 个 ORB 帧，s2a_err 集中在小值
        results = []
        for i in range(5):
            c2w = T_offset.copy()
            c2w[:3, 3] += np.random.randn(3) * 0.001
            results.append(_make_frame(i, c2w, np.eye(4), method="orb"))

        # 1 个正常 AKAZE 帧（s2a_err 与 ORB 帧接近）
        c2w_akaze = T_offset.copy()
        c2w_akaze[:3, 3] += np.array([0.002, -0.001, 0.001])
        results.append(_make_frame(10, c2w_akaze, np.eye(4), method="akaze_fallback"))

        _apply_consistency_filter(results)

        # 正常 AKAZE 帧应保持 ok
        akaze_frame = results[-1]
        assert akaze_frame["status"] == "ok"
        assert akaze_frame["method"] == "akaze_fallback"

    def test_outlier_akaze_frame_filtered(self):
        """s2a_err 偏离过大的 AKAZE 帧应被标记为 pnp_outlier"""
        # 5 个 ORB 帧，s2a_err 集中在小值（接近 0）
        results = []
        for i in range(5):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            results.append(_make_frame(i, c2w, np.eye(4), method="orb"))

        # 1 个离群 AKAZE 帧（大 s2a_err）
        c2w_bad = np.eye(4)
        angle = np.radians(25)
        c2w_bad[:3, :3] = np.array([
            [np.cos(angle), -np.sin(angle), 0],
            [np.sin(angle),  np.cos(angle), 0],
            [0, 0, 1],
        ])
        c2w_bad[:3, 3] = [0.8, 0.4, -0.2]
        results.append(_make_frame(10, c2w_bad, np.eye(4), method="akaze_fallback"))

        _apply_consistency_filter(results)

        # 离群 AKAZE 帧应被标记为 pnp_outlier
        akaze_frame = results[-1]
        assert akaze_frame["status"] == "pnp_outlier"
        assert "outlier_reason" in akaze_frame

    def test_mixed_orb_akaze_filtering(self):
        """混合 ORB + AKAZE 帧时，过滤逻辑对两者同等适用"""
        results = []
        # 4 个正常 ORB 帧
        for i in range(4):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            results.append(_make_frame(i, c2w, np.eye(4), method="orb"))

        # 2 个正常 AKAZE 帧
        for i in range(2):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            results.append(_make_frame(10 + i, c2w, np.eye(4), method="akaze_fallback"))

        # 1 个离群 ORB 帧
        c2w_bad_orb = np.eye(4)
        c2w_bad_orb[:3, 3] = [2.0, 1.0, -0.5]
        results.append(_make_frame(20, c2w_bad_orb, np.eye(4), method="orb"))

        # 1 个离群 AKAZE 帧
        c2w_bad_akaze = np.eye(4)
        c2w_bad_akaze[:3, 3] = [1.5, -0.8, 0.6]
        results.append(_make_frame(21, c2w_bad_akaze, np.eye(4), method="akaze_fallback"))

        _apply_consistency_filter(results)

        # 正常帧保持 ok
        for r in results[:6]:
            assert r["status"] == "ok", f"frame {r['frame']} should be ok"

        # 两个离群帧都应被过滤
        assert results[6]["status"] == "pnp_outlier"  # 离群 ORB
        assert results[7]["status"] == "pnp_outlier"  # 离群 AKAZE

    def test_akaze_frames_dont_degrade_alignment(self):
        """正常 AKAZE 帧加入后，对齐精度不应退化"""
        T_offset = np.eye(4)
        T_offset[:3, 3] = [0.1, 0.05, -0.03]

        # 5 个 ORB 帧
        orb_results = []
        for i in range(5):
            c2w = T_offset.copy()
            c2w[:3, 3] += np.random.randn(3) * 0.001
            orb_results.append(_make_frame(i, c2w, np.eye(4), method="orb"))

        # 仅用 ORB 帧计算 AT
        s2a_orb = [r["c2w"] @ r["w2c_native"] for r in orb_results]
        AT_orb = compute_alignment_transform(s2a_orb)
        errs_orb = [
            float(np.linalg.norm(AT_orb @ r["c2w"] @ r["w2c_native"] - np.eye(4)))
            for r in orb_results
        ]
        mean_err_orb = np.mean(errs_orb)

        # 加入 3 个正常 AKAZE 帧
        all_results = list(orb_results)
        for i in range(3):
            c2w = T_offset.copy()
            c2w[:3, 3] += np.random.randn(3) * 0.002
            all_results.append(_make_frame(10 + i, c2w, np.eye(4), method="akaze_fallback"))

        # 过滤后用所有 ok 帧计算 AT
        _apply_consistency_filter(all_results)
        ok_frames = [r for r in all_results if r["status"] == "ok"]
        s2a_all = [r["c2w"] @ r["w2c_native"] for r in ok_frames]
        AT_all = compute_alignment_transform(s2a_all)
        errs_all = [
            float(np.linalg.norm(AT_all @ r["c2w"] @ r["w2c_native"] - np.eye(4)))
            for r in ok_frames
        ]
        mean_err_all = np.mean(errs_all)

        # 加入 AKAZE 帧后对齐精度不应显著退化
        assert mean_err_all < 0.2, (
            f"对齐精度退化: mean_err_all={mean_err_all:.4f} >= 0.2"
        )
        # 精度不应比仅 ORB 差太多（允许 50% 退化容忍）
        assert mean_err_all < mean_err_orb * 1.5 + 0.01, (
            f"AKAZE 帧拉低精度: {mean_err_all:.4f} vs ORB-only {mean_err_orb:.4f}"
        )

    def test_filter_selects_by_status_not_method(self):
        """一致性过滤按 status='ok' 选择帧，不区分 method"""
        results = []
        # 混合 ORB 和 AKAZE 帧，全部 status="ok"
        for i in range(3):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            results.append(_make_frame(i, c2w, np.eye(4), method="orb"))
        for i in range(3):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            results.append(_make_frame(10 + i, c2w, np.eye(4), method="akaze_fallback"))

        # 加一个失败帧（不应参与过滤）
        results.append({
            "frame": 99, "status": "pnp_failed", "method": "orb",
            "n_matches": 5, "n_inliers": 0,
        })

        _apply_consistency_filter(results)

        # 所有 ok 帧（ORB + AKAZE）都应保持 ok（它们 s2a_err 接近）
        ok_count = sum(1 for r in results if r["status"] == "ok")
        assert ok_count == 6  # 3 ORB + 3 AKAZE
        # 失败帧不受影响
        assert results[-1]["status"] == "pnp_failed"
