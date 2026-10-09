#!/usr/bin/env python3
"""Public C ABI scaled fallback, original-grid geometry, trace and opt-out parity."""
import argparse,json,math,os,subprocess,tempfile,unittest
from pathlib import Path
BUILD=None
BASELINE_LIBRARY=None
class ScaledFallbackTest(unittest.TestCase):
    def run_fixture(self, mode='unchanged', setting=None, trace=None, library=None, expect_exit=0, recovery_mode=None):
        env=os.environ.copy()
        for key in ('VL_DIAGNOSTIC_TRACE','VL_DIAGNOSTIC_QUERY_LONG_EDGE','VL_DIAGNOSTIC_SCALED_FALLBACK','VL_DIAGNOSTIC_JOINT_POOL'): env.pop(key,None)
        if setting is not None:env['VL_DIAGNOSTIC_SCALED_FALLBACK']=setting
        if trace is not None:env['VL_DIAGNOSTIC_TRACE']=str(trace)
        # Obsolete unsafe global grid knob must have no effect in this experiment.
        env['VL_DIAGNOSTIC_QUERY_LONG_EDGE']='1600'
        selected_mode = (1 if setting == '1' else 0) if recovery_mode is None else recovery_mode
        run=subprocess.run([str(BUILD/'scaled_fallback_contract_test'),mode,str(library or BUILD/'libvisual_localizer.dylib'),str(selected_mode)],env=env,capture_output=True,text=True)
        self.assertEqual(run.returncode,expect_exit,run.stdout+run.stderr)
        return json.loads(run.stdout)
    def assert_correspondence_geometry(self,events,match):
        points=match['valid_correspondences']
        self.assertEqual(len(points),match['valid_3d_matches'])
        grid=next(e for e in events if e['event']=='query_pixel_grid' and
                  e['frame_ordinal']==match['frame_ordinal'] and e['phase']==match['phase'])
        fx,fy,cx,cy=grid['original_intrinsics'];pose=match['pose_camera_from_scan']
        squared=0.0
        for index in match['pnp_inlier_indices']:
            self.assertGreaterEqual(index,0);self.assertLess(index,len(points))
            point=points[index]
            self.assertEqual(point['kf_id'],match['kf_id'])
            self.assertGreaterEqual(point['query_index'],0);self.assertGreaterEqual(point['train_index'],0)
            self.assertEqual(len(point['uv_xyz_distance']),6)
            u,v,x,y,z,distance=point['uv_xyz_distance'];self.assertTrue(all(math.isfinite(a) for a in point['uv_xyz_distance']))
            camera_x=pose[0]*x+pose[1]*y+pose[2]*z+pose[3]
            camera_y=pose[4]*x+pose[5]*y+pose[6]*z+pose[7]
            depth=-(pose[8]*x+pose[9]*y+pose[10]*z+pose[11])
            self.assertGreater(depth,0)
            error_squared=(fx*camera_x/depth+cx-u)**2+(-fy*camera_y/depth+cy-v)**2
            squared+=error_squared
        recomputed=math.sqrt(squared/len(match['pnp_inlier_indices']))
        self.assertAlmostEqual(recomputed,match['reprojection_refined_rmse_px'],delta=.002)
    def test_unsupported_and_disabled_flags_match_frozen_baseline_bytes(self):
        expected=self.run_fixture(library=BASELINE_LIBRARY)
        for flag in (None,'','0','true','01','1junk'):
            with self.subTest(flag=flag): self.assertEqual(self.run_fixture(setting=flag),expected)
    def test_global_flags_cannot_override_explicit_standard(self):
        expected=self.run_fixture()
        self.assertEqual(self.run_fixture(setting='1',recovery_mode=0),expected)

    def test_non_exact_flags_cannot_recover_scaled_map(self):
        expected=self.run_fixture('orb1600',library=BASELINE_LIBRARY,expect_exit=1)
        for flag in (None,'','0','true','01','1junk'):
            with self.subTest(flag=flag):
                self.assertEqual(self.run_fixture('orb1600',setting=flag,expect_exit=1),expected)
    def test_non_integral_resize_keeps_original_k_and_pixel_gate(self):
        for mode,path in (('rounded_clean_orb','ORB'),('rounded_clean_akaze','AKAZE')):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='rounded-fallback-') as tmp:
                trace=Path(tmp)/'trace.jsonl';output=self.run_fixture(mode,'1',trace)
                self.assertEqual(output['original_dimensions'],[1921,1441])
                self.assertEqual(output['processed_dimensions'],[1600,1200])
                self.assertNotEqual(output['scale_xy'][0],output['scale_xy'][1])
                self.assertGreaterEqual(output['inliers'],550)
                events=[json.loads(line) for line in trace.read_text().splitlines()]
                grid=next(e for e in events if e['event']=='query_pixel_grid' and e['phase']=='scaled_fallback')
                self.assertEqual(grid['original_intrinsics'],grid['pnp_intrinsics'])
                self.assertEqual(grid['scale_xy'],[1600/1921,1200/1441])
                self.assertEqual(grid['pnp_reprojection_gate_original_px'],12)
                self.assertEqual(grid['pnp_coordinate_grid'],'original')
                self.assertTrue(grid['keypoint_remap_to_original'])
                match=next(e for e in events if e['event']=='match' and e['phase']=='scaled_fallback' and e['path']==path and e['rejection_reason']=='accepted')
                self.assertGreaterEqual(match['pnp_inliers'],550)
                self.assertLess(match['reprojection_refined_rmse_px'],.01)
                self.assert_correspondence_geometry(events,match)
    def test_lost_at_1600_edge_skips_fallback(self):
        with tempfile.TemporaryDirectory(prefix='skip-fallback-') as tmp:
            trace=Path(tmp)/'trace.jsonl';actual=self.run_fixture('lost1600','1',trace)
            self.assertEqual(actual,self.run_fixture('lost1600',library=BASELINE_LIBRARY))
            events=[json.loads(line) for line in trace.read_text().splitlines()]
            self.assertNotIn('scaled_fallback',{e['phase'] for e in events})
            choice=next(e for e in events if e['event']=='chosen_result')
            self.assertFalse(choice['fallback_attempted']);self.assertEqual(choice['chosen_phase'],'original')
    def test_original_success_untouched_when_opted_in(self):
        self.assertEqual(self.run_fixture(setting='1'),self.run_fixture(library=BASELINE_LIBRARY))
    def test_trace_labels_same_frame_two_passes_and_one_selection(self):
        with tempfile.TemporaryDirectory(prefix='scaled-fallback-') as tmp:
            trace=Path(tmp)/'trace.jsonl';off=self.run_fixture('orb1600','1');on=self.run_fixture('orb1600','1',trace)
            self.assertEqual(off,on)
            events=[json.loads(line) for line in trace.read_text().splitlines()]
            self.assertEqual({e['frame_ordinal'] for e in events},{1})
            self.assertEqual({e['phase'] for e in events},{'original','scaled_fallback','selection'})
            ends=[e for e in events if e['event']=='frame_end']
            self.assertEqual([(e['phase'],e['state']) for e in ends],[('original',2),('scaled_fallback',1)])
            choices=[e for e in events if e['event']=='chosen_result']
            self.assertEqual(len(choices),1);self.assertEqual(choices[0]['chosen_phase'],'scaled_fallback');self.assertTrue(choices[0]['reprojection_valid'])
            grid=next(e for e in events if e['event']=='query_pixel_grid' and e['phase']=='scaled_fallback')
            self.assertEqual(grid['original_dimensions'],[1920,1440]);self.assertEqual(grid['processed_dimensions'],[1600,1200])
            self.assertEqual(grid['original_intrinsics'],grid['pnp_intrinsics']);self.assertEqual(grid['pnp_intrinsics'],[1560,1540,960.25,721.75])
            self.assertEqual(grid['scale_xy'],[5/6,5/6]);self.assertEqual(grid['pnp_reprojection_gate_original_px'],12);self.assertEqual(grid['pnp_coordinate_grid'],'original');self.assertTrue(grid['keypoint_remap_to_original'])
    def test_original_success_emits_no_scaled_pass(self):
        with tempfile.TemporaryDirectory(prefix='scaled-fallback-') as tmp:
            trace=Path(tmp)/'trace.jsonl';self.run_fixture(setting='1',trace=trace)
            events=[json.loads(line) for line in trace.read_text().splitlines()]
            self.assertNotIn('scaled_fallback',{e['phase'] for e in events})
            choice=next(e for e in events if e['event']=='chosen_result');self.assertFalse(choice['fallback_attempted']);self.assertEqual(choice['chosen_phase'],'original')
    def test_final_original_pixel_outliers_rejected_in_both_extractors(self):
        for mode,path in (('gate_orb','ORB'),('gate_akaze','AKAZE'),('rounded_orb','ORB'),('rounded_akaze','AKAZE')):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='final-pixel-gate-') as tmp:
                trace=Path(tmp)/'trace.jsonl';output=self.run_fixture(mode,'1',trace)
                self.assertEqual(output['state'],2);self.assertEqual(output['inliers'],0)
                events=[json.loads(line) for line in trace.read_text().splitlines()]
                final=next(e for e in events if e['event']=='final_geometry' and e['phase']=='scaled_fallback' and e['path']==path)
                self.assertFalse(final['accepted']);self.assertEqual(final['rejection_reason'],'refined_original_pixel_gate')
                match=next(e for e in events if e['event']=='match' and e['phase']=='scaled_fallback' and e['path']==path)
                self.assertGreaterEqual(match['pnp_inliers'],530)
                self.assertEqual(match['rejection_reason'],'refined_original_pixel_gate')
                frame=next(e for e in events if e['event']=='query_pixel_grid' and e['phase']=='scaled_fallback')
                fx,fy,cx,cy=frame['original_intrinsics'];pose=final['candidate_pose_camera_from_scan'];errors=[]
                for i in match['pnp_inlier_indices']:
                    u,v,x,y,z,_=match['valid_correspondences'][i]['uv_xyz_distance']
                    xx=pose[0]*x+pose[1]*y+pose[2]*z+pose[3]
                    yy=-(pose[4]*x+pose[5]*y+pose[6]*z+pose[7])
                    depth=-(pose[8]*x+pose[9]*y+pose[10]*z+pose[11]);self.assertGreater(depth,0)
                    errors.append(math.hypot(fx*xx/depth+cx-u,fy*yy/depth+cy-v))
                self.assertGreater(max(errors),12)
                choice=next(e for e in events if e['event']=='chosen_result');self.assertEqual(choice['state'],2)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--baseline-library',type=Path,required=True)
    a,rest=p.parse_known_args();BUILD=a.build.resolve();BASELINE_LIBRARY=a.baseline_library.resolve();unittest.main(argv=[__file__]+rest)
