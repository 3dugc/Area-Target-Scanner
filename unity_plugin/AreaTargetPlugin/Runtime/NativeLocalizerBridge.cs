using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace AreaTargetPlugin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct VLDebugInfo
    {
        public int orb_keypoints;
        public int candidate_keyframes;
        public int best_kf_id;
        public int best_raw_matches;
        public int best_good_matches;
        public int best_inliers;
        public float best_bow_sim;
        // --- 新增字段（与 C 头文件 VLDebugInfo 末尾追加字段对应）---
        public float best_inlier_ratio;
        public int akaze_triggered;
        public int akaze_keypoints;
        public int akaze_best_inliers;
        public int consistency_rejected;
    }

    internal static class NativeLocalizerBridge
    {
#if UNITY_IOS && !UNITY_EDITOR
        private const string LibName = "__Internal";
#else
        private const string LibName = "visual_localizer";
#endif

        [DllImport(LibName)] internal static extern IntPtr vl_create();
        [DllImport(LibName)] internal static extern void vl_destroy(IntPtr handle);

        [DllImport(LibName)] internal static extern int vl_add_vocabulary_word(
            IntPtr handle, int word_id, byte[] descriptor, int desc_len, float idf_weight);

        [DllImport(LibName)] internal static extern int vl_add_keyframe(
            IntPtr handle, int kf_id, float[] pose_4x4,
            byte[] descriptors, int desc_count,
            float[] points3d, float[] points2d);

        [DllImport(LibName)] internal static extern int vl_build_index(IntPtr handle);

        [DllImport(LibName)]
        internal static extern int vl_add_keyframe_akaze(
            IntPtr handle, int kf_id,
            byte[] descriptors, int desc_count, int desc_len,
            float[] points3d, float[] points2d);

        [DllImport(LibName)] internal static extern void vl_reset(IntPtr handle);

        [DllImport(LibName)]
        internal static extern void vl_set_alignment_transform(
            IntPtr handle, float[] at_4x4);

        // --- Raw process_frame: returns flat buffer to avoid struct-return ABI issues ---
        // We P/Invoke the original vl_process_frame but marshal the return as IntPtr,
        // then manually read the fields. This avoids the iOS ARM64 IL2CPP struct-return bug.
        //
        // VLResult layout (C side): int state (4) + float[16] pose (64) + float confidence (4) + int matched (4) = 76 bytes
        // But with padding it's likely 76 bytes aligned.

        // Approach: call via raw pointer and manually unmarshal
        [DllImport(LibName, EntryPoint = "vl_process_frame")]
        private static extern void vl_process_frame_raw(
            IntPtr handle, byte[] image_data, int width, int height,
            float fx, float fy, float cx, float cy,
            int has_last_pose, float[] last_pose_4x4,
            IntPtr out_result);

        // Try the new out-parameter version first (if native lib has it), fall back to manual marshal
        [DllImport(LibName, EntryPoint = "vl_process_frame_out")]
        private static extern void vl_process_frame_out_native(
            IntPtr handle, byte[] image_data, int width, int height,
            float fx, float fy, float cx, float cy,
            int has_last_pose, float[] last_pose_4x4,
            IntPtr out_result);

        // --- Debug info ---
        [DllImport(LibName, EntryPoint = "vl_get_debug_info")]
        private static extern void vl_get_debug_info_native(IntPtr handle, IntPtr out_info);

        // Size of VLDebugInfo: 6 ints (24) + 1 float (4) + 1 float (4) + 4 ints (16) = 48 bytes
        private const int VLDebugInfoSize = 48;

        private static bool _hasDebugInfo = false;
        private static bool _checkedDebugInfo = false;

        /// <summary>
        /// Safe wrapper for vl_get_debug_info. Returns default if native lib doesn't have it.
        /// </summary>
        internal static VLDebugInfo GetDebugInfoSafe(IntPtr handle)
        {
            var info = new VLDebugInfo();
            info.best_kf_id = -1;

            if (!_checkedDebugInfo)
            {
                try
                {
                    IntPtr buf = Marshal.AllocHGlobal(VLDebugInfoSize);
                    try
                    {
                        vl_get_debug_info_native(handle, buf);
                        _hasDebugInfo = true;
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(buf);
                    }
                }
                catch (EntryPointNotFoundException)
                {
                    _hasDebugInfo = false;
                }
                _checkedDebugInfo = true;
            }

            if (!_hasDebugInfo)
                return info;

            IntPtr ptr = Marshal.AllocHGlobal(VLDebugInfoSize);
            try
            {
                vl_get_debug_info_native(handle, ptr);
                info.orb_keypoints = Marshal.ReadInt32(ptr, 0);
                info.candidate_keyframes = Marshal.ReadInt32(ptr, 4);
                info.best_kf_id = Marshal.ReadInt32(ptr, 8);
                info.best_raw_matches = Marshal.ReadInt32(ptr, 12);
                info.best_good_matches = Marshal.ReadInt32(ptr, 16);
                info.best_inliers = Marshal.ReadInt32(ptr, 20);
                info.best_bow_sim = BitConverter.ToSingle(
                    BitConverter.GetBytes(Marshal.ReadInt32(ptr, 24)), 0);
                // 新增字段 (offset 28+)
                info.best_inlier_ratio = BitConverter.ToSingle(
                    BitConverter.GetBytes(Marshal.ReadInt32(ptr, 28)), 0);
                info.akaze_triggered = Marshal.ReadInt32(ptr, 32);
                info.akaze_keypoints = Marshal.ReadInt32(ptr, 36);
                info.akaze_best_inliers = Marshal.ReadInt32(ptr, 40);
                info.consistency_rejected = Marshal.ReadInt32(ptr, 44);
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }

            return info;
        }

        // Size of VLResult: int(4) + float[16](64) + float(4) + int(4) = 76 bytes
        private const int VLResultSize = 76;
        private static int _diagFrameCount = 0;

        // Exposed for diagnostics
        internal static bool HasOutVersion => _hasOutVersion;
        internal static bool CheckedOutVersion => _checkedOutVersion;
        internal static bool HasDebugInfoApi => _hasDebugInfo;

        private static bool _hasOutVersion = false;
        private static bool _checkedOutVersion = false;

        /// <summary>
        /// Safe wrapper that avoids struct-return ABI issues on iOS ARM64.
        /// Allocates native memory, calls vl_process_frame writing to that buffer,
        /// then manually reads the fields.
        /// </summary>
        internal static VLResultData ProcessFrameSafe(
            IntPtr handle, byte[] imageData, int width, int height,
            float fx, float fy, float cx, float cy,
            int hasLastPose, float[] lastPose)
        {
            var result = new VLResultData();
            result.pose = new float[16];

            // Allocate unmanaged buffer for VLResult
            IntPtr buf = Marshal.AllocHGlobal(VLResultSize);
            try
            {
                // Zero it out
                unsafe
                {
                    byte* p = (byte*)buf;
                    for (int i = 0; i < VLResultSize; i++) p[i] = 0;
                }

                // Try _out version first, fall back to original
                if (!_checkedOutVersion)
                {
                    try
                    {
                        vl_process_frame_out_native(handle, imageData, width, height,
                            fx, fy, cx, cy, hasLastPose, lastPose, buf);
                        _hasOutVersion = true;
                    }
                    catch (EntryPointNotFoundException)
                    {
                        _hasOutVersion = false;
                    }
                    _checkedOutVersion = true;
                }

                if (_hasOutVersion)
                {
                    vl_process_frame_out_native(handle, imageData, width, height,
                        fx, fy, cx, cy, hasLastPose, lastPose, buf);
                }
                else
                {
                    // Original vl_process_frame returns VLResult by value.
                    // On iOS ARM64, large struct returns go via x8 register (pointer to caller-allocated space).
                    // We re-declare it as void with an extra IntPtr param to match the ABI.
                    vl_process_frame_raw(handle, imageData, width, height,
                        fx, fy, cx, cy, hasLastPose, lastPose, buf);
                }

                // Manually read fields from buffer
                result.state = Marshal.ReadInt32(buf, 0);
                for (int i = 0; i < 16; i++)
                {
                    result.pose[i] = BitConverter.ToSingle(
                        BitConverter.GetBytes(Marshal.ReadInt32(buf, 4 + i * 4)), 0);
                }
                result.confidence = BitConverter.ToSingle(
                    BitConverter.GetBytes(Marshal.ReadInt32(buf, 68)), 0);
                result.matched_features = Marshal.ReadInt32(buf, 72);

                // === DIAGNOSTIC: dump raw buffer for first 5 frames ===
                _diagFrameCount++;
                if (_diagFrameCount <= 5)
                {
                    int rawState = Marshal.ReadInt32(buf, 0);
                    int rawMatched = Marshal.ReadInt32(buf, 72);
                    int rawConfBits = Marshal.ReadInt32(buf, 68);
                    float rawConf = BitConverter.ToSingle(BitConverter.GetBytes(rawConfBits), 0);
                    // Read first 20 bytes as hex for pattern analysis
                    var hexBytes = new System.Text.StringBuilder();
                    unsafe
                    {
                        byte* bp = (byte*)buf;
                        for (int bi = 0; bi < 20; bi++)
                            hexBytes.AppendFormat("{0:X2} ", bp[bi]);
                    }
                    Debug.Log($"[VL_DIAG] frame={_diagFrameCount} outVer={_hasOutVersion} checked={_checkedOutVersion}" +
                        $" rawState={rawState} rawMatched={rawMatched} rawConf={rawConf} confBits=0x{rawConfBits:X8}" +
                        $" hex20=[{hexBytes}]" +
                        $" imgW={width} imgH={height} fx={fx:F1} fy={fy:F1} cx={cx:F1} cy={cy:F1}");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }

            return result;
        }
    }

    /// <summary>
    /// Managed version of VLResult, no marshalling issues.
    /// </summary>
    internal struct VLResultData
    {
        public int state;
        public float[] pose;
        public float confidence;
        public int matched_features;
    }
}
