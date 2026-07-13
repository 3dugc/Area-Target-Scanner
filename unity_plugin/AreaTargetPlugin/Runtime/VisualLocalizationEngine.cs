using System;
using System.Collections.Generic;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Visual localization engine that delegates ORB feature extraction, BoW-based
    /// keyframe retrieval, feature matching, and PnP pose estimation to the native
    /// C++ library (libvisual_localizer) via NativeLocalizerBridge.
    /// Works on all platforms (Editor, Standalone, iOS, Android) without OpenCvSharp.
    /// </summary>
    public class VisualLocalizationEngine : IDisposable
    {
        private IntPtr _nativeHandle;
        private bool _disposed;

        internal LocalizationMode CurrentMode { get; set; } = LocalizationMode.Raw;

        public bool Initialize(FeatureDatabaseReader featureDb)
        {
            if (featureDb == null || featureDb.KeyframeCount == 0)
            {
                Debug.LogError("[VisualLocalizationEngine] Feature database is null or empty.");
                return false;
            }

            _nativeHandle = NativeLocalizerBridge.vl_create();
            if (_nativeHandle == IntPtr.Zero)
            {
                Debug.LogError("[VisualLocalizationEngine] Failed to create native localizer.");
                return false;
            }

            // Load vocabulary
            foreach (var word in featureDb.Vocabulary)
            {
                NativeLocalizerBridge.vl_add_vocabulary_word(
                    _nativeHandle, word.WordId, word.Descriptor,
                    word.Descriptor.Length, word.IdfWeight);
            }

            // Load keyframes
            foreach (var kf in featureDb.Keyframes)
            {
                byte[] flatDesc = FlattenDescriptors(kf.Descriptors);
                float[] flatPts3d = FlattenPoints3D(kf.Points3D);
                float[] flatPts2d = FlattenPoints2D(kf.Keypoints2D);

                NativeLocalizerBridge.vl_add_keyframe(
                    _nativeHandle, kf.Id, kf.Pose,
                    flatDesc, kf.Descriptors.Count,
                    flatPts3d, flatPts2d);
            }

            // Load AKAZE features if available
            if (featureDb.HasAkazeFeatures)
            {
                foreach (var kf in featureDb.Keyframes)
                {
                    if (kf.AkazeDescriptors.Count == 0) continue;

                    byte[] flatAkazeDesc = FlattenAkazeDescriptors(kf.AkazeDescriptors);
                    float[] flatAkazePts3d = FlattenPoints3D(kf.AkazePoints3D);
                    float[] flatAkazePts2d = FlattenPoints2D(kf.AkazeKeypoints2D);

                    NativeLocalizerBridge.vl_add_keyframe_akaze(
                        _nativeHandle, kf.Id,
                        flatAkazeDesc, kf.AkazeDescriptors.Count, 61,
                        flatAkazePts3d, flatAkazePts2d);
                }
            }

            return NativeLocalizerBridge.vl_build_index(_nativeHandle) == 1;
        }

        /// <summary>
        /// Compatibility adapter for legacy CameraFrame callers. New Runtime code must
        /// submit LocalizationFrame so the current T_U_C is explicit and immutable.
        /// </summary>
        public TrackingResult ProcessFrame(CameraFrame frame)
        {
            if (!frame.TryCreateLocalizationFrame(out LocalizationFrame localizationFrame, out _))
                return CreateLostTrackingResult();

            return ToTrackingResult(ProcessFrame(localizationFrame));
        }

        /// <summary>
        /// Runs native PnP for one immutable frame. Native output is always named
        /// T_C_S; T_U_S is created only through CoordinateTransform.
        /// </summary>
        public LocalizationFrameResult ProcessFrame(
            LocalizationFrame frame,
            int mapGeneration = 0)
        {
            long workerStartedTimestampNs = GetMonotonicTimestampNs();
            float[] unityWorldFromCamera = PrepareUnityWorldFromCameraForNative(frame);

            // Use ProcessFrameSafe to avoid struct-return ABI issues on iOS ARM64
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                _nativeHandle, frame.GrayscaleImage, frame.Width, frame.Height,
                frame.Intrinsics.x, frame.Intrinsics.y,
                frame.Intrinsics.z, frame.Intrinsics.w,
                1, unityWorldFromCamera);
            long workerCompletedTimestampNs = GetMonotonicTimestampNs();
            VLDebugInfo nativeDebugInfo = GetDebugInfo();

            if ((TrackingState)result.state != TrackingState.TRACKING)
            {
                return LocalizationFrameResult.Failed(
                    frame,
                    mapGeneration,
                    workerStartedTimestampNs,
                    workerCompletedTimestampNs,
                    LocalizationFailureCategory.NativeLocalizationFailed,
                    nativeDebugInfo);
            }

            try
            {
                Matrix4x4 cameraFromScan = CoordinateTransform.FromNativeRowMajor(result.pose);
                LocalizationQuality quality = CurrentMode == LocalizationMode.Aligned
                    ? LocalizationQuality.LOCALIZED
                    : LocalizationQuality.RECOGNIZED;
                return LocalizationFrameResult.Succeeded(
                    frame,
                    mapGeneration,
                    workerStartedTimestampNs,
                    workerCompletedTimestampNs,
                    cameraFromScan,
                    quality,
                    result.confidence,
                    result.matched_features,
                    nativeDebugInfo);
            }
            catch (ArgumentException)
            {
                return LocalizationFrameResult.Failed(
                    frame,
                    mapGeneration,
                    workerStartedTimestampNs,
                    workerCompletedTimestampNs,
                    LocalizationFailureCategory.InvalidNativePose,
                    nativeDebugInfo);
            }
        }

        /// <summary>
        /// Marks Runtime alignment as established. Native PnP continues to return its
        /// canonical T_C_S pose; Runtime owns all T_U_S application.
        /// </summary>
        public void SetAlignmentTransform(Matrix4x4 unityWorldFromScanAlignment)
        {
            CoordinateTransform.ValidateFiniteRigidTransform(
                unityWorldFromScanAlignment, nameof(unityWorldFromScanAlignment));
            CurrentMode = LocalizationMode.Aligned;
        }

        public void ResetState()
        {
            CurrentMode = LocalizationMode.Raw;
            if (_nativeHandle != IntPtr.Zero)
                NativeLocalizerBridge.vl_reset(_nativeHandle);
        }

        /// <summary>
        /// Returns debug diagnostics from the last processed frame.
        /// Requires native lib with vl_get_debug_info; returns default if unavailable.
        /// </summary>
        internal VLDebugInfo GetDebugInfo()
        {
            if (_nativeHandle == IntPtr.Zero)
                return default;
            return NativeLocalizerBridge.GetDebugInfoSafe(_nativeHandle);
        }

        public void Dispose()
        {
            if (!_disposed && _nativeHandle != IntPtr.Zero)
            {
                NativeLocalizerBridge.vl_destroy(_nativeHandle);
                _nativeHandle = IntPtr.Zero;
                _disposed = true;
            }
        }

        #region Static Utility Methods

        /// <summary>
        /// Extracts the translation vector from a 4x4 pose matrix.
        /// </summary>
        public static Vector3 ExtractTranslation(Matrix4x4 pose)
        {
            return new Vector3(pose.m03, pose.m13, pose.m23);
        }

        /// <summary>
        /// Composes a 4x4 pose matrix from a 3x3 rotation matrix (row-major, 9 floats)
        /// and a translation vector (3 floats). Pure C# implementation, no OpenCV dependency.
        /// </summary>
        public static Matrix4x4 ComposePoseMatrix(float[] rotationMatrix, float[] translation)
        {
            var pose = new Matrix4x4();
            pose.m00 = rotationMatrix[0]; pose.m01 = rotationMatrix[1]; pose.m02 = rotationMatrix[2]; pose.m03 = translation[0];
            pose.m10 = rotationMatrix[3]; pose.m11 = rotationMatrix[4]; pose.m12 = rotationMatrix[5]; pose.m13 = translation[1];
            pose.m20 = rotationMatrix[6]; pose.m21 = rotationMatrix[7]; pose.m22 = rotationMatrix[8]; pose.m23 = translation[2];
            pose.m30 = 0f;               pose.m31 = 0f;               pose.m32 = 0f;               pose.m33 = 1f;
            return pose;
        }

        #endregion

        #region Helper Methods

        /// <summary>
        /// Concatenates a list of 32-byte ORB descriptors into a single flat byte array.
        /// </summary>
        internal static byte[] FlattenDescriptors(List<byte[]> descriptors)
        {
            if (descriptors == null || descriptors.Count == 0)
                return Array.Empty<byte>();

            byte[] flat = new byte[descriptors.Count * 32];
            for (int i = 0; i < descriptors.Count; i++)
            {
                Buffer.BlockCopy(descriptors[i], 0, flat, i * 32, 32);
            }
            return flat;
        }

        /// <summary>
        /// Concatenates a list of 61-byte AKAZE descriptors into a single flat byte array.
        /// </summary>
        internal static byte[] FlattenAkazeDescriptors(List<byte[]> descriptors)
        {
            if (descriptors == null || descriptors.Count == 0)
                return Array.Empty<byte>();

            byte[] flat = new byte[descriptors.Count * 61];
            for (int i = 0; i < descriptors.Count; i++)
            {
                Buffer.BlockCopy(descriptors[i], 0, flat, i * 61, 61);
            }
            return flat;
        }

        /// <summary>
        /// Flattens a list of 3D points to [x,y,z,x,y,z,...] float array.
        /// </summary>
        internal static float[] FlattenPoints3D(List<Vector3> points)
        {
            if (points == null || points.Count == 0)
                return Array.Empty<float>();

            float[] flat = new float[points.Count * 3];
            for (int i = 0; i < points.Count; i++)
            {
                flat[i * 3]     = points[i].x;
                flat[i * 3 + 1] = points[i].y;
                flat[i * 3 + 2] = points[i].z;
            }
            return flat;
        }

        /// <summary>
        /// Flattens a list of 2D points to [x,y,x,y,...] float array.
        /// </summary>
        internal static float[] FlattenPoints2D(List<Vector2> points)
        {
            if (points == null || points.Count == 0)
                return Array.Empty<float>();

            float[] flat = new float[points.Count * 2];
            for (int i = 0; i < points.Count; i++)
            {
                flat[i * 2]     = points[i].x;
                flat[i * 2 + 1] = points[i].y;
            }
            return flat;
        }

        /// <summary>
        /// Converts a Unity Matrix4x4 to a row-major float[16] array.
        /// Layout: [m00,m01,m02,m03, m10,m11,m12,m13, m20,m21,m22,m23, m30,m31,m32,m33]
        /// </summary>
        internal static float[] Matrix4x4ToArray(Matrix4x4 m)
        {
            return CoordinateTransform.ToNativeRowMajor(m);
        }

        /// <summary>
        /// Serializes current T_U_C for the native bridge as row-major float[16].
        /// </summary>
        internal static float[] PrepareUnityWorldFromCameraForNative(
            LocalizationFrame frame)
        {
            return CoordinateTransform.ToNativeRowMajor(frame.UnityWorldFromCamera);
        }

        /// <summary>
        /// Converts a row-major float[16] array to a Unity Matrix4x4.
        /// </summary>
        internal static Matrix4x4 ArrayToMatrix4x4(float[] arr)
        {
            if (arr == null || arr.Length < 16)
                return Matrix4x4.identity;

            try
            {
                return CoordinateTransform.FromNativeRowMajor(arr);
            }
            catch (ArgumentException)
            {
                return Matrix4x4.identity;
            }
        }

        private static TrackingResult CreateLostTrackingResult()
        {
            return new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0,
                Quality = LocalizationQuality.NONE
            };
        }

        private static TrackingResult ToTrackingResult(LocalizationFrameResult result)
        {
            return new TrackingResult
            {
                State = result.State,
                Pose = result.UnityWorldFromScan ?? Matrix4x4.identity,
                Confidence = result.Confidence,
                MatchedFeatures = result.MatchedFeatures,
                Quality = result.Quality
            };
        }

        private static long GetMonotonicTimestampNs()
        {
            long ticks = System.Diagnostics.Stopwatch.GetTimestamp();
            long frequency = System.Diagnostics.Stopwatch.Frequency;
            long seconds = ticks / frequency;
            long remainder = ticks % frequency;
            return seconds * 1000000000L + remainder * 1000000000L / frequency;
        }

        #endregion
    }
}
