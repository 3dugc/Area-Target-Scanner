using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    public interface ICameraData
    {
        byte[] GetBytes();
        int Width { get; }
        int Height { get; }
        int Channels { get; }
        Vector4 Intrinsics { get; }              // fx, fy, cx, cy
        Vector3 CameraPositionOnCapture { get; }
        Quaternion CameraRotationOnCapture { get; }
        long FrameId { get; }
        long CaptureTimestampNs { get; }
        ImageOrientation Orientation { get; }
        string MapId { get; }
    }
}
