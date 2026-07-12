using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for CameraDataAdapter ICameraData → CameraFrame conversion.
    /// Feature: pointcloud-localization, Property 11: ICameraData 到 CameraFrame 转换保留数据
    /// **Validates: Requirements 10.2**
    /// </summary>
    [TestFixture]
    public class CameraDataAdapterPropertyTests
    {
        /// <summary>
        /// Stub ICameraData implementation for property testing.
        /// </summary>
        private class StubCameraData : ICameraData
        {
            private readonly byte[] _bytes;

            public StubCameraData(byte[] bytes, int width, int height, int channels, Vector4 intrinsics)
            {
                _bytes = bytes;
                Width = width;
                Height = height;
                Channels = channels;
                Intrinsics = intrinsics;
            }

            public byte[] GetBytes() => _bytes;
            public int Width { get; }
            public int Height { get; }
            public int Channels { get; }
            public Vector4 Intrinsics { get; }
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
        }

        /// <summary>
        /// Property 11: For any ICameraData, after converting to CameraFrame:
        /// - CameraFrame.ImageData should equal ICameraData.GetBytes()
        /// - CameraFrame.Width and Height should match ICameraData
        /// - CameraFrame.Intrinsics (m00, m11, m02, m12) should respectively equal
        ///   ICameraData.Intrinsics (x, y, z, w)
        /// **Validates: Requirements 10.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ToCameraFrame_PreservesAllData(PositiveInt w, PositiveInt h, float fx, float fy, float cx, float cy)
        {
            var bytes = new byte[w.Get * h.Get];
            var intrinsics = new Vector4(fx, fy, cx, cy);
            var cameraData = new StubCameraData(bytes, w.Get, h.Get, 1, intrinsics);

            var frame = CameraDataAdapter.ToCameraFrame(cameraData);

            bool imageDataMatch = ReferenceEquals(frame.ImageData, bytes);
            bool widthMatch = frame.Width == w.Get;
            bool heightMatch = frame.Height == h.Get;
            bool fxMatch = Mathf.Approximately(frame.Intrinsics.m00, fx);
            bool fyMatch = Mathf.Approximately(frame.Intrinsics.m11, fy);
            bool cxMatch = Mathf.Approximately(frame.Intrinsics.m02, cx);
            bool cyMatch = Mathf.Approximately(frame.Intrinsics.m12, cy);

            return (imageDataMatch && widthMatch && heightMatch && fxMatch && fyMatch && cxMatch && cyMatch)
                .ToProperty()
                .Label($"ToCameraFrame should preserve ImageData (ref), Width={w.Get}, Height={h.Get}, fx={fx}, fy={fy}, cx={cx}, cy={cy}");
        }
    }
}
