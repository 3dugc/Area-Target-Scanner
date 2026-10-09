using System;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>
    /// Default ILocalizer implementation that wraps VisualLocalizationEngine and FeatureDatabaseReader.
    /// Converts ICameraData to CameraFrame, runs ProcessFrame, and converts TrackingResult to ILocalizationResult.
    /// </summary>
    public class PointCloudLocalizer : ILocalizer, ILocalizationSessionLifecycle
    {
        private const int ResultPollLimit = 100;

        private AsyncLocalizationRunner _runner;
        private FeatureDatabaseReader _featureDb;
        private NativeSessionBridge _session;
        private LocalizationTrackingMetadata? _lastTrackingMetadata;
        private readonly int _mapId;
        private bool _disposed;
        private uint _platformTrackingQuality = 2;
        public int MapId => _mapId;
        public void SetPlatformTrackingQuality(uint trackingQuality)
        {
            if (trackingQuality > 2) throw new ArgumentOutOfRangeException(nameof(trackingQuality));
            _platformTrackingQuality = trackingQuality;
        }
        public async Task ResetTrackingAsync()
        {
            _session?.Dispose(); _session = null; _lastTrackingMetadata = null;
            if (_runner != null) await _runner.ResetAsync();
        }


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
                    return FailedForMap();

                if (cameraData == null)
                    return FailedForMap();

                if (cameraData.Width <= 0 || cameraData.Height <= 0)
                    return FailedForMap();

                var frame = CameraDataAdapter.ToCameraFrame(cameraData);
                var sourceMetadata = frame.TrackingMetadata.Value;
                frame.TrackingMetadata = new LocalizationTrackingMetadata(sourceMetadata.CameraId,
                    sourceMetadata.CaptureClockEpoch, sourceMetadata.TrackingEpoch, sourceMetadata.PoseTimestampNs,
                    Math.Min(sourceMetadata.TrackingQuality, _platformTrackingQuality),
                    sourceMetadata.ClockMappingValid, sourceMetadata.ExtrinsicsValid);
                if (!frame.TryCreateLocalizationFrame(
                    out LocalizationFrame localizationFrame,
                    out _))
                {
                    return FailedForMap();
                }

                if (_runner == null) return FailedForMap();
                if (_session == null) _session = new NativeSessionBridge();
                var metadata = localizationFrame.TrackingMetadata;
                if (_lastTrackingMetadata.HasValue)
                {
                    var previous = _lastTrackingMetadata.Value;
                    if (previous.CameraId != metadata.CameraId
                        || previous.CaptureClockEpoch != metadata.CaptureClockEpoch
                        || previous.TrackingEpoch != metadata.TrackingEpoch
                        || (previous.TrackingQuality == 2 && metadata.TrackingQuality != 2))
                    {
                        await _runner.ResetAsync();
                        _session.Reset((ulong)_runner.CurrentGeneration, metadata.TrackingEpoch);
                        _lastTrackingMetadata = metadata;
                        return FailedForMap();
                    }
                }
                _lastTrackingMetadata = metadata;
                if (!_runner.Submit(localizationFrame)) return FailedForMap();
                for (int attempt = 0; attempt < ResultPollLimit; attempt++)
                {
                    if (_disposed) return FailedForMap();
                    TrackingResult display;
                    if (_runner.TryTakeLatestForSession(out LocalizationFrameResult frameResult))
                    {
                        // Report genuine engine successes independently of whether
                        // C++ has confirmed an alignment or is displaying propagation.
                        if (frameResult.IsSuccess)
                            OnSuccessfulLocalizations?.Invoke(new[] { _mapId });
                        display = _session.Update(frameResult, LocalizationClock.NowTimestampNs);
                    }
                    else
                    {
                        display = _session.Poll(LocalizationClock.NowTimestampNs);
                    }
                    if (display.Quality != LocalizationQuality.NONE)
                        return new LocalizationResult { Success = true, MapId = _mapId, Pose = display.Pose };
                    await Task.Delay(1);
                }

                return FailedForMap();
            }
            catch (Exception ex)
            {
                Debug.LogError($"[PointCloudLocalizer] Localize exception: {ex.Message}");
                return FailedForMap();
            }
        }

        private ILocalizationResult FailedForMap()
            => new LocalizationResult { Success = false, MapId = _mapId, Pose = UnityEngine.Matrix4x4.identity };

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
            _session?.Dispose();
            _session = null;

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
