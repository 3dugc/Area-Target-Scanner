using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>
    /// Editor-only IPlatformSupport implementation that returns simulated camera data.
    /// Used for development and testing in Unity Editor without a real AR device.
    /// </summary>
    public class EditorPlatformSupport : IPlatformSupport
    {
        private bool _configured;
        private bool _disposed;
        private int _simulatedWidth = 640;
        private int _simulatedHeight = 480;
        private long _nextFrameId;

        /// <summary>Map identifier attached to simulated frames.</summary>
        public string MapId { get; set; } = "editor-simulated-map";

        public async Task<IPlatformUpdateResult> UpdatePlatform()
        {
            if (_disposed || !_configured)
                return new PlatformUpdateResult { Success = false, TrackingQuality = 0, CameraData = null };

            long frameId = _nextFrameId++;
            var cameraData = new EditorCameraData(
                _simulatedWidth,
                _simulatedHeight,
                frameId,
                frameId * 1000000L,
                MapId);
            await Task.CompletedTask;
            return new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 100,
                CameraData = cameraData
            };
        }

        public Task ConfigurePlatform()
        {
            _configured = true;
            Debug.Log("[EditorPlatformSupport] Configured with simulated camera data.");
            return Task.CompletedTask;
        }

        public Task StopAndCleanUp()
        {
            if (_disposed) return Task.CompletedTask;
            _disposed = true;
            _configured = false;
            return Task.CompletedTask;
        }

        private class EditorCameraData : ICameraData
        {
            private readonly byte[] _bytes;
            public int Width { get; }
            public int Height { get; }
            public int Channels => 1;
            public Vector4 Intrinsics => new Vector4(500f, 500f, Width / 2f, Height / 2f);
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
            public long FrameId { get; }
            public long CaptureTimestampNs { get; }
            public ImageOrientation Orientation => ImageOrientation.LandscapeRight;
            public string MapId { get; }

            public EditorCameraData(
                int width,
                int height,
                long frameId,
                long captureTimestampNs,
                string mapId)
            {
                Width = width;
                Height = height;
                FrameId = frameId;
                CaptureTimestampNs = captureTimestampNs;
                MapId = mapId;
                _bytes = new byte[width * height];
            }

            public byte[] GetBytes() => _bytes;
        }
    }
}
