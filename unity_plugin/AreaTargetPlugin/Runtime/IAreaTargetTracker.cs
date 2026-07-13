using System;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Interface for the area target tracker. Provides methods to load an asset bundle,
    /// process camera frames for 6DoF localization, and manage tracking lifecycle.
    /// </summary>
    public interface IAreaTargetTracker : IDisposable
    {
        /// <summary>
        /// Loads the area target asset bundle from the given path and initializes
        /// the tracking engine. On success, sets tracking state to INITIALIZING.
        /// </summary>
        /// <param name="assetPath">Path to the area target asset directory containing
        /// manifest.json, mesh.obj, texture_atlas.png, and features.db.</param>
        /// <returns>True if initialization succeeded, false otherwise.</returns>
        bool Initialize(string assetPath);

        /// <summary>
        /// Processes a single camera frame and returns the tracking result.
        /// </summary>
        /// <param name="cameraFrame">The current camera frame with image data and intrinsics.</param>
        /// <returns>Tracking result containing state, pose, confidence, and matched features.</returns>
        TrackingResult ProcessFrame(CameraFrame cameraFrame);

        /// <summary>
        /// Processes an immutable localization frame that contains the current T_U_C.
        /// </summary>
        TrackingResult ProcessFrame(LocalizationFrame localizationFrame);

        /// <summary>
        /// Returns the current tracking state.
        /// </summary>
        TrackingState GetTrackingState();

        /// <summary>
        /// Resets the tracker, clearing current tracking state and Kalman filter,
        /// and restarts localization from scratch.
        /// </summary>
        void Reset();
    }
}
