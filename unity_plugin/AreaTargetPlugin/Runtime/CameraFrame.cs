using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Represents a camera frame with image data and intrinsics for tracking.
    /// </summary>
    public struct CameraFrame
    {
        /// <summary>Grayscale image data (row-major, single channel).</summary>
        public byte[] ImageData;

        /// <summary>Image width in pixels.</summary>
        public int Width;

        /// <summary>Image height in pixels.</summary>
        public int Height;

        /// <summary>Camera intrinsic matrix (3x3).</summary>
        public Matrix4x4 Intrinsics;

        /// <summary>
        /// Current T_U_C camera pose, when the frame came from an AR platform.
        /// A null value preserves legacy callers that do not provide AR tracking data.
        /// </summary>
        public Matrix4x4? UnityWorldFromCamera;
    }
}
