using System;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>
    /// Default ILocalizer implementation that wraps VisualLocalizationEngine and FeatureDatabaseReader.
    /// Converts ICameraData to CameraFrame, runs ProcessFrame, and converts TrackingResult to ILocalizationResult.
    /// </summary>
    public class PointCloudLocalizer : ILocalizer
    {
        private const int ResultPollLimit = 100;
        private const long MaxLocalizationResultAgeNs = 1_000_000_000L;

        private AsyncLocalizationRunner _runner;
        private FeatureDatabaseReader _featureDb;
        private readonly int _mapId;
        private bool _disposed;

        public event Action<int[]> OnSuccessfulLocalizations;

        /// <summary>
        /// Creates a PointCloudLocalizer with pre-initialized engine and feature database.
        /// </summary>
        /// <param name="mapId">The map identifier for this localizer.</param>
        /// <param name="engine">An initialized VisualLocalizationEngine.</param>
        /// <param name="featureDb">A loaded FeatureDatabaseReader.</param>
        public PointCloudLocalizer(int mapId, VisualLocalizationEngine engine, FeatureDatabaseReader featureDb)
        {
            _mapId = mapId;
            if (engine != null)
            {
                _runner = new AsyncLocalizationRunner(engine);
                _runner.Start();
            }
            _featureDb = featureDb;
        }

        /// <summary>
        /// Performs point cloud localization on the given camera data.
        /// Returns Failed() for null input, invalid dimensions, disposed state, or internal exceptions.
        /// Fires OnSuccessfulLocalizations when tracking succeeds.
        /// </summary>
        public async Task<ILocalizationResult> Localize(ICameraData cameraData)
        {
            try
            {
                if (_disposed)
                    return LocalizationResult.Failed();

                if (cameraData == null)
                    return LocalizationResult.Failed();

                if (cameraData.Width <= 0 || cameraData.Height <= 0)
                    return LocalizationResult.Failed();

                var frame = CameraDataAdapter.ToCameraFrame(cameraData);
                if (!frame.TryCreateLocalizationFrame(
                    out LocalizationFrame localizationFrame,
                    out _))
                {
                    return LocalizationResult.Failed();
                }

                if (_runner == null || !_runner.Submit(localizationFrame))
                    return LocalizationResult.Failed();

                for (int attempt = 0; attempt < ResultPollLimit; attempt++)
                {
                    if (_runner.TryDequeueLatest(
                        localizationFrame.MapId,
                        _runner.CurrentGeneration,
                        localizationFrame.CaptureTimestampNs,
                        MaxLocalizationResultAgeNs,
                        out LocalizationFrameResult frameResult))
                    {
                        if (frameResult.IsSuccess)
                        {
                            var result = new LocalizationResult
                            {
                                Success = true,
                                MapId = _mapId,
                                Pose = frameResult.UnityWorldFromScan.Value
                            };
                            OnSuccessfulLocalizations?.Invoke(new[] { _mapId });
                            return result;
                        }

                        return LocalizationResult.Failed();
                    }

                    await Task.Delay(1);
                }

                return LocalizationResult.Failed();
            }
            catch (Exception ex)
            {
                Debug.LogError($"[PointCloudLocalizer] Localize exception: {ex.Message}");
                return LocalizationResult.Failed();
            }
        }

        /// <summary>
        /// Releases VisualLocalizationEngine and FeatureDatabaseReader resources and marks this localizer as disposed.
        /// After calling this, all subsequent Localize calls return Failed().
        /// Each resource is disposed in its own try-catch to ensure one failure doesn't prevent the other from being released.
        /// The _disposed flag is set before disposal so concurrent Localize calls see it immediately.
        /// </summary>
        public async Task StopAndCleanUp()
        {
            if (_disposed) return;
            _disposed = true;

            try
            {
                if (_runner != null)
                    await _runner.DisposeAsync();
            }
            catch (Exception ex)
            {
                Debug.LogError($"[PointCloudLocalizer] Error disposing runner: {ex.Message}");
            }
            _runner = null;

            try
            {
                _featureDb?.Dispose();
            }
            catch (Exception ex)
            {
                Debug.LogError($"[PointCloudLocalizer] Error disposing feature database: {ex.Message}");
            }
            _featureDb = null;
        }
    }
}
