using System;
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

        /// <summary>Monotonic identifier assigned to this captured frame.</summary>
        public long FrameId;

        /// <summary>Monotonic AR capture timestamp in nanoseconds.</summary>
        public long CaptureTimestampNs;

        /// <summary>Orientation after the source platform's image normalization.</summary>
        public ImageOrientation Orientation;

        /// <summary>Stable identifier of the map used for this localization request.</summary>
        public string MapId;

        /// <summary>
        /// Current T_U_C camera pose, when the frame came from an AR platform.
        /// A null value preserves legacy callers that do not provide AR tracking data.
        /// </summary>
        public Matrix4x4? UnityWorldFromCamera;

        /// <summary>
        /// Creates the immutable runtime payload and rejects incomplete legacy frames.
        /// </summary>
        public bool TryCreateLocalizationFrame(
            out LocalizationFrame localizationFrame,
            out string error)
        {
            localizationFrame = default;
            error = null;

            if (!UnityWorldFromCamera.HasValue)
            {
                error = "Camera frame is missing current T_U_C.";
                return false;
            }

            try
            {
                localizationFrame = new LocalizationFrame(
                    FrameId,
                    CaptureTimestampNs,
                    ImageData,
                    Width,
                    Height,
                    new Vector4(Intrinsics.m00, Intrinsics.m11, Intrinsics.m02, Intrinsics.m12),
                    Orientation,
                    UnityWorldFromCamera.Value,
                    MapId);
                return true;
            }
            catch (ArgumentException exception)
            {
                error = exception.Message;
                return false;
            }
        }
    }
}
