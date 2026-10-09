#!/usr/bin/env python3
"""Real native rejection-stage trace contract; run against a supplied build."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BUILD = None

class DiagnosticTraceTest(unittest.TestCase):
    def run_fixture(self, mode, trace=None):
        env = os.environ.copy()
        for key in ("VL_DIAGNOSTIC_TRACE", "VL_DIAGNOSTIC_SCALED_FALLBACK", "VL_DIAGNOSTIC_JOINT_POOL", "VL_DIAGNOSTIC_QUERY_LONG_EDGE"):
            env.pop(key, None)
        if trace is not None:
            env["VL_DIAGNOSTIC_TRACE"] = str(trace)
        result = subprocess.run(
            [str(BUILD / "visual_localizer_localization_contract_test"), mode],
            env=env, capture_output=True, text=True, check=True,
        )
        return result.stdout

    def test_real_orb_crosscheck_rejection_and_akaze_pnp_acceptance(self):
        with tempfile.TemporaryDirectory(prefix="vl-diagnostic-test-") as tmp:
            trace = Path(tmp) / "events.jsonl"
            self.run_fixture("akaze_diagnostics", trace)
            self.assertTrue(trace.exists(), "opt-in trace must expose the real native rejection stage")
            events = [json.loads(line) for line in trace.read_text().splitlines()]
            orb = next(e for e in events if e["event"] == "match" and e["path"] == "ORB")
            self.assertEqual(orb["rejection_reason"], "insufficient_cross_checked_matches")
            self.assertLess(orb["cross_checked_matches"], 8)
            self.assertIsNone(orb["pnp_success"])
            akaze = next(e for e in events if e["event"] == "match" and e["path"] == "AKAZE")
            self.assertIs(akaze["pnp_success"], True)
            self.assertGreaterEqual(akaze["pnp_inliers"], 100)
            self.assertEqual(akaze["rejection_reason"], "accepted")
            self.assertEqual(len(akaze["pose_camera_from_scan"]), 16)
            self.assertIsNotNone(akaze["reprojection_refined_rmse_px"])
            self.assertEqual(orb["valid_correspondences"], [])
            correspondences = akaze["valid_correspondences"]
            self.assertEqual(len(correspondences), akaze["valid_3d_matches"])
            frame = next(e for e in events if e["event"] == "frame_start" and
                         e["frame_ordinal"] == akaze["frame_ordinal"] and e["phase"] == akaze["phase"])
            pose = akaze["pose_camera_from_scan"]
            squared = 0.0
            for index in akaze["pnp_inlier_indices"]:
                self.assertGreaterEqual(index, 0); self.assertLess(index, len(correspondences))
                point = correspondences[index]
                self.assertEqual(point["kf_id"], akaze["kf_id"])
                self.assertGreaterEqual(point["query_index"], 0)
                self.assertGreaterEqual(point["train_index"], 0)
                self.assertEqual(len(point["uv_xyz_distance"]), 6)
                u,v,x,y,z,distance = point["uv_xyz_distance"]
                self.assertTrue(all(math.isfinite(a) for a in point["uv_xyz_distance"]))
                camera_x = pose[0]*x+pose[1]*y+pose[2]*z+pose[3]
                camera_y = pose[4]*x+pose[5]*y+pose[6]*z+pose[7]
                optical_depth = -(pose[8]*x+pose[9]*y+pose[10]*z+pose[11])
                self.assertGreater(optical_depth, 0)
                projected_u = frame["fx"]*camera_x/optical_depth+frame["cx"]
                projected_v = -frame["fy"]*camera_y/optical_depth+frame["cy"]
                squared += (projected_u-u)**2+(projected_v-v)**2
            recomputed = math.sqrt(squared/len(akaze["pnp_inlier_indices"]))
            self.assertAlmostEqual(recomputed, akaze["reprojection_refined_rmse_px"], delta=.002)
            self.assertTrue(any(e["event"] == "retrieval" and e["source"] == "global_bow" for e in events))
            end = [e for e in events if e["event"] == "frame_end"]
            self.assertEqual(len(end), 2)
            self.assertEqual(end[0]["frame_ordinal"], 1)
            self.assertEqual(end[0]["state"], 1)
            self.assertEqual(end[1]["frame_ordinal"], 2)
            self.assertEqual(end[1]["state"], 2)
            self.assertTrue(any(e["event"] == "features" and e["path"] == "AKAZE" and e["rejection_reason"] == "empty_features" for e in events))

    def test_trace_off_emits_no_file_and_on_preserves_fixture_output(self):
        with tempfile.TemporaryDirectory(prefix="vl-diagnostic-test-") as tmp:
            trace = Path(tmp) / "events.jsonl"
            off = self.run_fixture("akaze_diagnostics")
            self.assertFalse(trace.exists())
            on = self.run_fixture("akaze_diagnostics", trace)
            self.assertEqual(off, on)
            self.assertTrue(trace.exists(), "trace must be created when explicitly enabled")

    def test_unwritable_trace_does_not_change_native_output(self):
        off = self.run_fixture("akaze_diagnostics")
        bad = self.run_fixture("akaze_diagnostics", Path("/nonexistent/vl-trace/events.jsonl"))
        self.assertEqual(off, bad)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BUILD = args.build.resolve()
    unittest.main(argv=[__file__] + remaining)
