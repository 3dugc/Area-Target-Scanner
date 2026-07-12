"""
summarize() 方法分类统计的单元测试
验证需求 11.5, 11.6: 分别输出 ORB/AKAZE/rescued 帧数，每帧输出定位方法标记
"""
import sys, os
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import summarize


def _make_ok_frame(idx, method="orb", status="ok"):
    """构造一个成功帧结果"""
    return {
        "frame": idx, "status": status, "method": method,
        "n_matches": 30, "n_inliers": 15, "inlier_ratio": 0.5,
        "s2a_err": 0.1, "rot_err": 1.0,
    }


def _make_failed_frame(idx, status="pnp_failed"):
    """构造一个失败帧结果"""
    return {"frame": idx, "status": status, "n_matches": 5}


class TestSummarizeMethodBreakdown:
    """验证 summarize() 返回的 n_orb, n_akaze, n_rescued, n_failed 字段"""

    def test_orb_only(self):
        """纯 ORB 成功帧"""
        results = [_make_ok_frame(i, method="orb") for i in range(5)]
        summary = summarize(results, "test")
        assert summary["n_orb"] == 5
        assert summary["n_akaze"] == 0
        assert summary["n_rescued"] == 0
        assert summary["n_failed"] == 0
        assert summary["ok"] == 5

    def test_mixed_methods(self):
        """ORB + AKAZE + rescued + failed 混合"""
        results = [
            _make_ok_frame(0, method="orb"),
            _make_ok_frame(1, method="orb"),
            _make_ok_frame(2, method="akaze_fallback"),
            _make_ok_frame(3, method="orb", status="ok_rescued"),
            _make_failed_frame(4, status="pnp_failed"),
            _make_failed_frame(5, status="few_matches"),
        ]
        summary = summarize(results, "mixed")
        assert summary["n_orb"] == 3  # 2 ok + 1 ok_rescued (method=orb)
        assert summary["n_akaze"] == 1
        assert summary["n_rescued"] == 1
        assert summary["n_failed"] == 2
        assert summary["ok"] == 4
        assert summary["total"] == 6

    def test_all_failed(self):
        """全部失败"""
        results = [_make_failed_frame(i) for i in range(3)]
        summary = summarize(results, "fail")
        assert summary["n_orb"] == 0
        assert summary["n_akaze"] == 0
        assert summary["n_rescued"] == 0
        assert summary["n_failed"] == 3
        assert summary["ok"] == 0

    def test_akaze_rescued_frame(self):
        """AKAZE fallback 帧被救回的情况"""
        results = [
            _make_ok_frame(0, method="akaze_fallback", status="ok_rescued"),
        ]
        summary = summarize(results, "akaze_rescued")
        # akaze_fallback + ok_rescued: 同时计入 n_akaze 和 n_rescued
        assert summary["n_akaze"] == 1
        assert summary["n_rescued"] == 1
        assert summary["n_orb"] == 0

    def test_empty_results(self):
        """空结果"""
        summary = summarize([], "empty")
        assert summary["n_orb"] == 0
        assert summary["n_akaze"] == 0
        assert summary["n_rescued"] == 0
        assert summary["n_failed"] == 0
        assert summary["total"] == 0

    def test_summary_dict_has_all_fields(self):
        """验证返回的 dict 包含所有必要字段"""
        results = [_make_ok_frame(0)]
        summary = summarize(results, "fields")
        required_keys = {"label", "total", "ok", "rate", "n_orb", "n_akaze",
                         "n_rescued", "n_failed", "mean_s2a_err", "mean_rot_err",
                         "mean_inlier_ratio", "status_counts"}
        assert required_keys.issubset(set(summary.keys()))
