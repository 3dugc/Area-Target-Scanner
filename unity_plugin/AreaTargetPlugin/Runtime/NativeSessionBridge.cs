using System;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace AreaTargetPlugin
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct AtcSessionConfig
    {
        internal uint StructSize, ApiVersion, WindowSize, InitializationSamples, RecoverySamples;
        internal float MaxTranslationResidualM, MaxRotationResidualRad;
        internal ulong MaxPoseSkewNs, MaxAlignmentAgeNs, MaxResultAgeNs;
        internal float SmoothingTauSeconds;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct AtcRawResult
    {
        internal uint StructSize, ApiVersion;
        internal int Status;
        internal uint RawPoseValid;
        internal ulong FrameId, CaptureTimestampNs, MapGeneration, CaptureClockEpoch, CameraId, MapInstanceId;
        internal fixed float CameraFromScan[16];
        internal uint Inliers;
        internal float Confidence, ReprojectionRmsePx;
        internal uint ReprojectionErrorValid;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct AtcTrackingSample
    {
        internal uint StructSize, ApiVersion;
        internal ulong FrameId, CaptureTimestampNs, MapGeneration, CaptureClockEpoch, CameraId;
        internal ulong PoseTimestampNs, TrackingEpoch;
        internal uint ClockMappingValid, PoseValid, ExtrinsicsValid, TrackingQuality;
        internal fixed float WorldFromCamera[16];
    }

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct AtcSessionResult
    {
        internal uint StructSize, ApiVersion;
        internal int Status;
        internal uint RawPoseValid, AlignmentValid, PropagatedPoseValid, State, Mode, RejectionReason;
        internal ulong FrameId, CaptureTimestampNs, MapGeneration, CaptureClockEpoch, CameraId;
        internal ulong MapInstanceId, TrackingEpoch, AlignmentAgeNs;
        internal fixed float CameraFromScan[16];
        internal fixed float WorldFromScan[16];
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AtcConsensusConfig
    {
        internal uint StructSize, ApiVersion, MinimumInliers, MaximumCandidates;
        internal float MinimumInlierRatio, MaximumTranslationM, MaximumRotationRad;
        internal uint Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct AtcConsensusResult
    {
        internal uint StructSize, ApiVersion, Valid, RejectionReason, MatchedCount, InlierCount, SelectedIndex;
        internal float MaximumTranslationResidualM, MaximumRotationResidualRad;
        internal fixed float MapFromScan[16];
    }

    /// <summary>
    /// Serial FFI owner for the shared C++ Session in the same DLL as legacy vl_*.
    /// Contains coordinate/identity conversion only; C++ owns every localization policy.
    /// </summary>
    internal unsafe sealed class NativeSessionBridge : IDisposable
    {
        private const uint ApiVersion = 2;
        private readonly object _gate = new object();
        private IntPtr _handle;
        private AtcSessionResult _lastNativeResult;
        internal AtcSessionResult LastNativeResult { get { lock (_gate) return _lastNativeResult; } }

        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_get_default_session_config_v2(ref AtcSessionConfig config);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_session_create(ref AtcSessionConfig config, out IntPtr handle);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_session_update_at(IntPtr handle, ref AtcRawResult raw,
            ref AtcTrackingSample tracking, ulong nowNs, ref AtcSessionResult result);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_session_poll(IntPtr handle, ulong nowNs, ref AtcSessionResult result);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_session_reset(IntPtr handle, ulong generation, ulong trackingEpoch);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern void atc_session_destroy(ref IntPtr handle);

        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_get_default_rigid_consensus_config_v2(ref AtcConsensusConfig config);
        [DllImport(NativeLocalizerBridge.LibName, CallingConvention = CallingConvention.Cdecl)]
        private static extern int atc_estimate_rigid_consensus_v2(ref AtcConsensusConfig config,
            float* candidates, uint count, ref AtcConsensusResult result);
        internal static bool TryConsensus(System.Collections.Generic.IReadOnlyList<LocalizationFramePair> pairs,
            out Matrix4x4 unityWorldFromScan)
        {
            unityWorldFromScan = Matrix4x4.identity;
            if (pairs == null || pairs.Count == 0) return false;
            var config = new AtcConsensusConfig { StructSize = (uint)sizeof(AtcConsensusConfig), ApiVersion = ApiVersion };
            RequireOk(atc_get_default_rigid_consensus_config_v2(ref config), "default rigid consensus profile");
            var values = new float[checked(pairs.Count * 16)];
            for (int index = 0; index < pairs.Count; index++)
            {
                var pose = RightHandedWorldToUnity(pairs[index].UnityWorldFromScan);
                CoordinateTransform.ToNativeRowMajor(pose).CopyTo(values, index * 16);
            }
            var result = new AtcConsensusResult { StructSize = (uint)sizeof(AtcConsensusResult), ApiVersion = ApiVersion };
            fixed (float* data = values)
            {
                if (atc_estimate_rigid_consensus_v2(ref config, data, (uint)pairs.Count, ref result) != 0 || result.Valid == 0)
                    return false;
            }
            var selected = new float[16];
            for (int i = 0; i < 16; i++) selected[i] = result.MapFromScan[i];
            unityWorldFromScan = RightHandedWorldToUnity(CoordinateTransform.FromNativeRowMajor(selected));
            return true;
        }

        internal static AtcSessionConfig DefaultConfig()
        {
            var config = new AtcSessionConfig { StructSize = (uint)sizeof(AtcSessionConfig), ApiVersion = ApiVersion };
            RequireOk(atc_get_default_session_config_v2(ref config), "default Session profile");
            return config;
        }

        internal NativeSessionBridge() : this(DefaultConfig()) { }
        internal NativeSessionBridge(AtcSessionConfig config)
        {
            config.StructSize = (uint)sizeof(AtcSessionConfig);
            config.ApiVersion = ApiVersion;
            RequireOk(atc_session_create(ref config, out _handle), "create Session");
        }

        internal TrackingResult Update(LocalizationFrameResult frame, long nowTimestampNs)
        {
            if (nowTimestampNs < 0) throw new ArgumentOutOfRangeException(nameof(nowTimestampNs));
            var metadata = frame.TrackingMetadata;
            var raw = RawHeader(frame.FrameId, frame.CaptureTimestampNs, frame.MapGeneration,
                metadata, MapIdentity(frame.MapId));
            raw.Status = frame.IsSuccess ? 0 : 1;
            raw.RawPoseValid = frame.IsSuccess ? 1u : 0u;
            raw.Inliers = frame.IsSuccess ? (uint)frame.MatchedFeatures : 0;
            raw.Confidence = frame.IsSuccess ? frame.Confidence : 0;
            if (frame.IsSuccess)
                Write(LegacyCameraToOptical(frame.CameraFromScan.Value), raw.CameraFromScan);
            var tracking = TrackingHeader(raw, metadata);
            Write(UnityCameraToRightHandedOptical(frame.UnityWorldFromCamera), tracking.WorldFromCamera);
            return Update(raw, tracking, nowTimestampNs, raw.Confidence, raw.Inliers);
        }

        // Source-compatible pose utilities may delegate here. Their bare input is
        // explicitly a Unity content transform, not a visual localization result.
        internal TrackingResult UpdateWorldPose(Matrix4x4 unityWorldFromScan, long frameId, long timestampNs)
        {
            var metadata = LocalizationTrackingMetadata.KnownClock(timestampNs);
            var raw = RawHeader(frameId, timestampNs, 0, metadata, 1);
            raw.Status = 0; raw.RawPoseValid = 1;
            Write(RightHandedWorldToUnity(unityWorldFromScan), raw.CameraFromScan);
            var tracking = TrackingHeader(raw, metadata);
            Write(Matrix4x4.identity, tracking.WorldFromCamera);
            return Update(raw, tracking, timestampNs, 0, 0);
        }

        private TrackingResult Update(AtcRawResult raw, AtcTrackingSample tracking,
            long nowNs, float confidence, uint inliers)
        {
            lock (_gate)
            {
                EnsureAlive();
                var result = ResultHeader();
                atc_session_update_at(_handle, ref raw, ref tracking, (ulong)nowNs, ref result);
                _lastNativeResult = result;
                return ToTrackingResult(result, confidence, inliers);
            }
        }

        internal TrackingResult Poll(long nowTimestampNs)
        {
            if (nowTimestampNs < 0) throw new ArgumentOutOfRangeException(nameof(nowTimestampNs));
            lock (_gate)
            {
                EnsureAlive();
                var result = ResultHeader();
                atc_session_poll(_handle, (ulong)nowTimestampNs, ref result);
                _lastNativeResult = result;
                return ToTrackingResult(result, 0, 0);
            }
        }

        internal void Reset(ulong generation, ulong trackingEpoch)
        {
            lock (_gate)
            {
                EnsureAlive();
                RequireOk(atc_session_reset(_handle, generation, trackingEpoch), "reset Session");
                _lastNativeResult = default;
            }
        }

        public void Dispose()
        {
            lock (_gate)
                if (_handle != IntPtr.Zero) atc_session_destroy(ref _handle);
            GC.SuppressFinalize(this);
        }
        ~NativeSessionBridge() { Dispose(); }

        internal static Matrix4x4 LegacyCameraToOptical(Matrix4x4 cameraArFromScan)
            => Basis(1, -1, -1) * cameraArFromScan;
        internal static Matrix4x4 UnityCameraToRightHandedOptical(Matrix4x4 unityWorldFromCamera)
            => Basis(1, 1, -1) * unityWorldFromCamera * Basis(1, -1, 1);
        internal static Matrix4x4 RightHandedWorldToUnity(Matrix4x4 rightHandedWorldFromScan)
            => Basis(1, 1, -1) * rightHandedWorldFromScan * Basis(1, 1, -1);
        private static Matrix4x4 Basis(float x, float y, float z)
        {
            var basis = Matrix4x4.identity;
            basis.m00 = x; basis.m11 = y; basis.m22 = z;
            return basis;
        }

        private static AtcRawResult RawHeader(long id, long capture, long generation,
            LocalizationTrackingMetadata metadata, ulong mapInstance)
        {
            return new AtcRawResult {
                StructSize = (uint)sizeof(AtcRawResult), ApiVersion = ApiVersion,
                FrameId = checked((ulong)id), CaptureTimestampNs = checked((ulong)capture),
                MapGeneration = checked((ulong)generation), CaptureClockEpoch = metadata.CaptureClockEpoch,
                CameraId = metadata.CameraId, MapInstanceId = mapInstance
            };
        }
        private static AtcTrackingSample TrackingHeader(AtcRawResult raw, LocalizationTrackingMetadata metadata)
        {
            return new AtcTrackingSample {
                StructSize = (uint)sizeof(AtcTrackingSample), ApiVersion = ApiVersion,
                FrameId = raw.FrameId, CaptureTimestampNs = raw.CaptureTimestampNs,
                MapGeneration = raw.MapGeneration, CaptureClockEpoch = raw.CaptureClockEpoch,
                CameraId = raw.CameraId, PoseTimestampNs = checked((ulong)metadata.PoseTimestampNs),
                TrackingEpoch = metadata.TrackingEpoch, ClockMappingValid = metadata.ClockMappingValid ? 1u : 0u,
                PoseValid = 1, ExtrinsicsValid = metadata.ExtrinsicsValid ? 1u : 0u,
                TrackingQuality = metadata.TrackingQuality
            };
        }
        private static AtcSessionResult ResultHeader()
            => new AtcSessionResult { StructSize = (uint)sizeof(AtcSessionResult), ApiVersion = ApiVersion };
        private static TrackingResult ToTrackingResult(AtcSessionResult native, float confidence, uint inliers)
        {
            var result = new TrackingResult {
                State = native.State == 2 ? TrackingState.LOST : TrackingState.INITIALIZING,
                Pose = Matrix4x4.identity, Quality = LocalizationQuality.NONE
            };
            if (native.AlignmentValid == 0) return result;
            var values = new float[16];
            for (int i = 0; i < 16; i++) values[i] = native.WorldFromScan[i];
            result.Pose = RightHandedWorldToUnity(CoordinateTransform.FromNativeRowMajor(values));
            result.State = TrackingState.TRACKING;
            bool visualEvidence = native.RawPoseValid == 1 && native.Mode == 2 && native.Status == 0;
            result.Quality = visualEvidence ? LocalizationQuality.LOCALIZED : LocalizationQuality.RECOGNIZED;
            result.Confidence = visualEvidence ? confidence : 0;
            result.MatchedFeatures = visualEvidence ? checked((int)inliers) : 0;
            return result;
        }
        private static void Write(Matrix4x4 matrix, float* destination)
        {
            float[] values = CoordinateTransform.ToNativeRowMajor(matrix);
            for (int i = 0; i < 16; i++) destination[i] = values[i];
        }
        private static ulong MapIdentity(string mapId)
        {
            ulong hash = 14695981039346656037UL;
            foreach (byte value in Encoding.UTF8.GetBytes(mapId ?? string.Empty))
                hash = unchecked((hash ^ value) * 1099511628211UL);
            return hash == 0 ? 1 : hash;
        }
        private void EnsureAlive()
        {
            if (_handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(NativeSessionBridge));
        }
        private static void RequireOk(int status, string operation)
        {
            if (status != 0) throw new InvalidOperationException($"Native {operation} failed: {status}.");
        }
    }
}
