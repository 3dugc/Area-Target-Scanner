using System;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Orientation of a grayscale image before it enters the localization runtime.
    /// Runtime frames are normalized to <see cref="LandscapeRight"/>.
    /// </summary>
    public enum ImageOrientation
    {
        LandscapeRight = 0,
        LandscapeLeft = 1,
        Portrait = 2,
        PortraitUpsideDown = 3,
        Unknown = 4
    }

    /// <summary>
    /// Immutable payload for a single localization request.
    /// The image is copied on construction and every image getter returns a copy.
    /// </summary>
    public readonly struct LocalizationFrame
    {
        private readonly byte[] _grayscaleImage;

        public long FrameId { get; }
        public long CaptureTimestampNs { get; }
        public int Width { get; }
        public int Height { get; }
        public Vector4 Intrinsics { get; }
        public ImageOrientation Orientation { get; }

        /// <summary>T_U_C: current camera pose from camera coordinates C into Unity world U.</summary>
        public Matrix4x4 UnityWorldFromCamera { get; }

        public string MapId { get; }

        /// <summary>
        /// Single-channel, row-major grayscale image. A defensive copy is returned
        /// so a frame cannot be modified after it is submitted.
        /// </summary>
        public byte[] GrayscaleImage => _grayscaleImage == null
            ? Array.Empty<byte>()
            : (byte[])_grayscaleImage.Clone();

        public LocalizationFrame(
            long frameId,
            long captureTimestampNs,
            byte[] grayscaleImage,
            int width,
            int height,
            Vector4 intrinsics,
            ImageOrientation orientation,
            Matrix4x4 unityWorldFromCamera,
            string mapId)
        {
            if (frameId < 0)
                throw new ArgumentException("Frame ID must be non-negative.", nameof(frameId));
            if (captureTimestampNs < 0)
                throw new ArgumentException("Capture timestamp must be non-negative.", nameof(captureTimestampNs));
            if (width <= 0 || height <= 0)
                throw new ArgumentException("Frame dimensions must be positive.");
            if (grayscaleImage == null)
                throw new ArgumentNullException(nameof(grayscaleImage));

            long expectedImageLength = (long)width * height;
            if (grayscaleImage.Length != expectedImageLength)
                throw new ArgumentException(
                    "Grayscale image length must equal width multiplied by height.",
                    nameof(grayscaleImage));
            if (!ArePositiveFinite(intrinsics))
                throw new ArgumentException("Camera intrinsics must be finite and positive.", nameof(intrinsics));
            if (orientation != ImageOrientation.LandscapeRight)
                throw new ArgumentException(
                    "Localization frames must use normalized LandscapeRight image orientation.",
                    nameof(orientation));
            if (!CoordinateTransform.IsFiniteRigidTransform(unityWorldFromCamera))
                throw new ArgumentException(
                    "UnityWorldFromCamera must be a finite rigid transform.",
                    nameof(unityWorldFromCamera));
            if (string.IsNullOrWhiteSpace(mapId))
                throw new ArgumentException("Map ID must not be empty.", nameof(mapId));

            FrameId = frameId;
            CaptureTimestampNs = captureTimestampNs;
            _grayscaleImage = (byte[])grayscaleImage.Clone();
            Width = width;
            Height = height;
            Intrinsics = intrinsics;
            Orientation = orientation;
            UnityWorldFromCamera = unityWorldFromCamera;
            MapId = mapId;
        }

        private static bool ArePositiveFinite(Vector4 intrinsics)
        {
            return IsPositiveFinite(intrinsics.x)
                && IsPositiveFinite(intrinsics.y)
                && IsPositiveFinite(intrinsics.z)
                && IsPositiveFinite(intrinsics.w);
        }

        private static bool IsPositiveFinite(float value)
        {
            return value > 0f && !float.IsNaN(value) && !float.IsInfinity(value);
        }
    }
}
