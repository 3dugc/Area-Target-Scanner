using System;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>
    /// AR Foundation-based IPlatformSupport implementation.
    /// Uses ARCameraManager for camera frames, XRCameraSubsystem for intrinsics,
    /// and XROrigin for tracking pose. Compatible with ARKit XR Plugin (iOS) and
    /// OpenXR Plugin (Rokid/Pico/Quest) without platform-specific code branches.
    /// Requires com.unity.xr.arfoundation package.
    ///
    /// Coordinate system conversion is performed before returning ICameraData,
    /// ensuring all poses are in Unity left-handed Y-up coordinate system.
    /// </summary>
    public class ARFoundationPlatformSupport : IPlatformSupport
    {
        private bool _configured;
        private bool _disposed;
        private long _nextFrameId;
        private CapturePoseSnapshot _latestPoseSnapshot;
        private Vector4 _latestIntrinsics;
        private ulong _trackingEpoch;
        private uint _lastTrackingQuality;
        private Camera _captureCamera;
        private ulong _cameraIdentity;
        /// <summary>Explicit provider-to-LocalizationClock calibration; never inferred from arrival.</summary>
        public ICaptureClockMapper CaptureClockMapper { get; set; }
        /// <summary>Set only after the host verifies camera transform represents the event exposure.</summary>
        public bool PoseSampleIsFrameBound { get; set; }

        /// <summary>Stable map identifier attached to each acquired AR frame.</summary>
        public string MapId { get; set; } = "default-map";

#if UNITY_AR_FOUNDATION
        // AR Foundation references (resolved during ConfigurePlatform)
        private UnityEngine.XR.ARFoundation.ARCameraManager _cameraManager;
        private Unity.XR.CoreUtils.XROrigin _xrOrigin;
#endif

        public async Task<IPlatformUpdateResult> UpdatePlatform()
        {
            if (_disposed || !_configured)
            {
                return new PlatformUpdateResult
                {
                    Success = false,
                    TrackingQuality = 0,
                    CameraData = null
                };
            }

#if UNITY_AR_FOUNDATION
            return await AcquireFrameFromARFoundation();
#else
            await Task.CompletedTask;
            Debug.LogWarning(
                "[ARFoundationPlatformSupport] AR Foundation package not available. " +
                "Install com.unity.xr.arfoundation and add UNITY_AR_FOUNDATION to scripting defines.");
            return new PlatformUpdateResult
            {
                Success = false,
                TrackingQuality = 0,
                CameraData = null
            };
#endif
        }

        public Task ConfigurePlatform()
        {
            if (_disposed)
            {
                Debug.LogError("[ARFoundationPlatformSupport] Cannot configure after disposal.");
                return Task.CompletedTask;
            }

#if UNITY_AR_FOUNDATION
            ConfigureARFoundation();
#else
            Debug.LogWarning(
                "[ARFoundationPlatformSupport] AR Foundation package not available. " +
                "Skipping platform configuration.");
#endif
            _configured = true;
            return Task.CompletedTask;
        }

        public Task StopAndCleanUp()
        {
            if (_disposed) return Task.CompletedTask;

            _disposed = true;
            _configured = false;

#if UNITY_AR_FOUNDATION
            CleanUpARFoundation();
#endif
            return Task.CompletedTask;
        }

#if UNITY_AR_FOUNDATION
        private void ConfigureARFoundation()
        {
            // Find ARCameraManager in scene — works for both ARKit and OpenXR providers
            _cameraManager = UnityEngine.Object.FindAnyObjectByType<UnityEngine.XR.ARFoundation.ARCameraManager>();
            if (_cameraManager == null)
            {
                Debug.LogError("[ARFoundationPlatformSupport] ARCameraManager not found in scene.");
                return;
            }

            // Find XROrigin — unified tracking root for all AR Foundation providers
            _xrOrigin = UnityEngine.Object.FindAnyObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (_xrOrigin == null)
            {
                Debug.LogError("[ARFoundationPlatformSupport] XROrigin not found in scene.");
                return;
            }

            _cameraManager.frameReceived += OnCameraFrameReceived;
        }

        private void OnCameraFrameReceived(UnityEngine.XR.ARFoundation.ARCameraFrameEventArgs args)
        {
            if (_xrOrigin == null || _xrOrigin.Camera == null) return;
            uint quality = EvaluateTrackingQuality() == 100 ? 2u : 1u;
            if (_lastTrackingQuality == 2 && quality != 2) _trackingEpoch++;
            _lastTrackingQuality = quality;
            if (_captureCamera != _xrOrigin.Camera) { _captureCamera = _xrOrigin.Camera; _cameraIdentity++; }
            var cameraTransform = _captureCamera.transform;
            _latestPoseSnapshot = new CapturePoseSnapshot(args.timestampNs, LocalizationClock.NowTimestampNs,
                cameraTransform.localToWorldMatrix, _trackingEpoch, quality, PoseSampleIsFrameBound);
            if (_cameraManager.subsystem != null && _cameraManager.subsystem.TryGetIntrinsics(out var k))
                _latestIntrinsics = new Vector4(k.focalLength.x, k.focalLength.y, k.principalPoint.x, k.principalPoint.y);

        }

        private async Task<IPlatformUpdateResult> AcquireFrameFromARFoundation()
        {
            // 1. Acquire latest CPU image from ARCameraManager
            //    This API is provider-agnostic: works with ARKit XR Plugin and OpenXR Plugin
            if (_cameraManager == null || _xrOrigin == null || _xrOrigin.Camera == null
                || !_cameraManager.TryAcquireLatestCpuImage(out var cpuImage))
            {
                return new PlatformUpdateResult { Success = false, TrackingQuality = 0, CameraData = null };
            }

            try
            {
                // 2. Get camera intrinsics from XRCameraSubsystem
                //    AR Foundation abstracts ARKit/OpenXR intrinsics into a unified XRCameraIntrinsics
                var subsystem = _cameraManager.subsystem;
                if (subsystem == null || !subsystem.TryGetIntrinsics(out var intrinsics))
                {
                    return new PlatformUpdateResult { Success = false, TrackingQuality = 0, CameraData = null };
                }

                // 3. Get tracking pose from XROrigin camera
                //    XROrigin.Camera provides the tracked camera transform in Unity world space
                var snapshot = _latestPoseSnapshot;
                if (!CaptureFrameBinding.TryBind(cpuImage.timestamp, snapshot, CaptureClockMapper,
                    _cameraIdentity, out var binding))
                    return new PlatformUpdateResult { Success = false, TrackingQuality = 0, CameraData = null };
                var position = binding.UnityWorldFromCamera.GetColumn(3);
                var rotation = binding.UnityWorldFromCamera.rotation;

                // 4. Convert CPU image to byte array (grayscale preferred for feature extraction)
                var conversionParams = new UnityEngine.XR.ARSubsystems.XRCpuImage.ConversionParams
                {
                    inputRect = new RectInt(0, 0, cpuImage.width, cpuImage.height),
                    outputDimensions = new Vector2Int(cpuImage.width, cpuImage.height),
                    outputFormat = UnityEngine.TextureFormat.R8,
                    transformation = UnityEngine.XR.ARSubsystems.XRCpuImage.Transformation.None
                };

                int bufferSize = cpuImage.GetConvertedDataSize(conversionParams);
                var imageBytes = new byte[bufferSize];

                unsafe
                {
                    fixed (byte* ptr = imageBytes)
                    {
                        cpuImage.Convert(conversionParams, (IntPtr)ptr, bufferSize);
                    }
                }

                // 5. Coordinate system conversion:
                //    AR Foundation already provides poses in Unity left-handed Y-up coordinate system
                //    for both ARKit and OpenXR providers. No additional conversion needed here
                //    because XROrigin handles the provider-to-Unity transform internally.
                //
                //    If a non-AR-Foundation platform (e.g., Rokid UXR SDK) uses a different
                //    coordinate convention, a custom IPlatformSupport implementation should
                //    handle the conversion before returning ICameraData.

                // 6. Assess tracking quality from ARSession state
                int trackingQuality = EvaluateTrackingQuality();
                long captureTimestampNs = binding.CaptureTimestampNs;

                var cameraData = new ARFoundationCameraData(
                    imageBytes,
                    cpuImage.width,
                    cpuImage.height,
                    channels: 1, // grayscale
                    _latestIntrinsics.x > 0 ? _latestIntrinsics : new Vector4(intrinsics.focalLength.x, intrinsics.focalLength.y,
                                intrinsics.principalPoint.x, intrinsics.principalPoint.y),
                    position,
                    rotation,
                    _nextFrameId++,
                    captureTimestampNs,
                    ImageOrientation.LandscapeRight,
                    MapId,
                    binding.TrackingMetadata
                );

                return new PlatformUpdateResult
                {
                    Success = true,
                    TrackingQuality = trackingQuality,
                    CameraData = cameraData
                };
            }
            finally
            {
                cpuImage.Dispose();
            }
        }

        private int EvaluateTrackingQuality()
        {
            // Map ARSession tracking state to 0-100 quality score
            // This works identically for ARKit and OpenXR providers
            var state = UnityEngine.XR.ARFoundation.ARSession.state;
            switch (state)
            {
                case UnityEngine.XR.ARFoundation.ARSessionState.SessionTracking:
                    return 100;
                case UnityEngine.XR.ARFoundation.ARSessionState.SessionInitializing:
                    return 30;
                case UnityEngine.XR.ARFoundation.ARSessionState.Ready:
                    return 10;
                default:
                    return 0;
            }
        }

        private void CleanUpARFoundation()
        {
            if (_cameraManager != null)
                _cameraManager.frameReceived -= OnCameraFrameReceived;
            _cameraManager = null;
            _xrOrigin = null;
        }

        /// <summary>
        /// Internal ICameraData implementation for AR Foundation frames.
        /// </summary>
        private class ARFoundationCameraData : ICameraData, ILocalizationTrackingMetadataSource
        {
            private readonly byte[] _bytes;
            public int Width { get; }
            public int Height { get; }
            public int Channels { get; }
            public Vector4 Intrinsics { get; }
            public Vector3 CameraPositionOnCapture { get; }
            public Quaternion CameraRotationOnCapture { get; }
            public long FrameId { get; }
            public long CaptureTimestampNs { get; }
            public ImageOrientation Orientation { get; }
            public string MapId { get; }
            public LocalizationTrackingMetadata TrackingMetadata { get; }

            public ARFoundationCameraData(
                byte[] bytes, int width, int height, int channels,
                Vector4 intrinsics, Vector3 position, Quaternion rotation,
                long frameId, long captureTimestampNs,
                ImageOrientation orientation, string mapId, LocalizationTrackingMetadata trackingMetadata)
            {
                _bytes = bytes;
                Width = width;
                Height = height;
                Channels = channels;
                Intrinsics = intrinsics;
                CameraPositionOnCapture = position;
                CameraRotationOnCapture = rotation;
                FrameId = frameId;
                CaptureTimestampNs = captureTimestampNs;
                Orientation = orientation;
                MapId = mapId;
                TrackingMetadata = trackingMetadata;
            }

            public byte[] GetBytes() => _bytes;
        }
#endif
    }
}
