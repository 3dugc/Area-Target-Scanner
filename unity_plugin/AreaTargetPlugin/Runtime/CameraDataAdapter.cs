using UnityEngine;
using AreaTargetPlugin;

namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>
    /// Converts ICameraData to the existing CameraFrame format used by VisualLocalizationEngine.
    /// </summary>
    public static class CameraDataAdapter
    {
        /// <summary>
        /// Converts an ICameraData instance to a CameraFrame.
        /// Maps Intrinsics from Vector4 (fx, fy, cx, cy) to a 4x4 intrinsic matrix.
        /// </summary>
        public static CameraFrame ToCameraFrame(ICameraData cameraData)
        {
            var intr = cameraData.Intrinsics;
            Matrix4x4 intrinsicMatrix = Matrix4x4.identity;
            intrinsicMatrix.m00 = intr.x;  // fx
            intrinsicMatrix.m11 = intr.y;  // fy
            intrinsicMatrix.m02 = intr.z;  // cx
            intrinsicMatrix.m12 = intr.w;  // cy

            return new CameraFrame
            {
                ImageData = cameraData.GetBytes(),
                Width = cameraData.Width,
                Height = cameraData.Height,
                Intrinsics = intrinsicMatrix,
                FrameId = cameraData.FrameId,
                CaptureTimestampNs = cameraData.CaptureTimestampNs,
                Orientation = cameraData.Orientation,
                MapId = cameraData.MapId,
                UnityWorldFromCamera = Matrix4x4.TRS(
                    cameraData.CameraPositionOnCapture,
                    cameraData.CameraRotationOnCapture,
                    Vector3.one
                )
            };
        }
    }
}
