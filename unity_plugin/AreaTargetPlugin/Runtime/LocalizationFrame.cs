using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Minimal phase-1 localization payload for the current AR camera pose.
    /// Full image, timestamp, and map metadata are added in task 4.
    /// </summary>
    public readonly struct LocalizationFrame
    {
        /// <summary>
        /// T_U_C: current camera pose from camera coordinates C into Unity world U.
        /// </summary>
        public Matrix4x4 UnityWorldFromCamera { get; }

        public LocalizationFrame(Matrix4x4 unityWorldFromCamera)
        {
            UnityWorldFromCamera = unityWorldFromCamera;
        }
    }
}
