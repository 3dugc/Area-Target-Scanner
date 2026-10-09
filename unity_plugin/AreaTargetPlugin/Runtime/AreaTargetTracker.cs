using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Main implementation of the area target tracker.
    /// Loads asset bundles and provides 6DoF visual localization.
    /// Delegates raw recognition and alignment policy to the shared C++ core.
    /// 
    /// The shared Core performs raw recognition; Session confirms, gates, smooths,
    /// and expires alignment. This host owns lifecycle and Unity display only.
    /// </summary>
    /// <remarks>
    /// Privacy: No network permissions required. Camera data is processed locally only.
    /// This class does not use HttpClient, WebRequest, or any networking APIs.
    /// Camera access is only used during active tracking via ProcessFrame.
    /// Requirements: 15.3, 15.4
    /// </remarks>
    public class AreaTargetTracker : IAreaTargetTracker
    {
        private TrackingState _state = TrackingState.INITIALIZING;
        private AssetBundleLoader _loader;
        private VisualLocalizationEngine _localizationEngine;
        private AsyncLocalizationRunner _localizationRunner;
        private FeatureDatabaseReader _featureDb;
        private bool _initialized;
        private bool _disposed;
        private Task _disposeTask;
        private VLDebugInfo _lastNativeDebugInfo;
        private readonly BoundedDiagnosticBuffer _diagnosticBuffer = new BoundedDiagnosticBuffer(256);
        private readonly object _diagnosticStateGate = new object();
        private readonly string _diagnosticBuildVersion;
        private readonly string _diagnosticDeviceModel;
        private readonly string _diagnosticOperatingSystem;
        private LocalizationDiagnosticRecord _lastDiagnosticRecord;
        private string _diagnosticMapId = "map-unavailable";
        private string _diagnosticMapVersion = "unknown";
        private string _diagnosticMapHash = "unknown";

        private const long DefaultMaxResultAgeNs = 3_000_000_000L;
        private const string RuntimePackageVersion = "1.3.0";

        // --- 可配置属性 (Requirements 5.4, 5.8, 6.6) ---
        /// <summary>触发首次 AT 计算的最小 Raw 模式成功帧数。</summary>
        [Obsolete("The shared C++ default profile owns confirmation; this legacy count is unused.")]
        public int AlignmentFrameThreshold { get; set; } = 2;
        /// <summary>Aligned 模式下 AT 刷新间隔（成功帧数）。</summary>
        [Obsolete("Session alignment is updated by the shared C++ profile; this legacy frame interval is unused.")]
        public int ATRefreshInterval { get; set; } = 20;
        /// <summary>Aligned 模式滑动窗口大小。</summary>
        [Obsolete("The shared C++ default profile owns its window; this legacy count is unused.")]
        public int SlidingWindowSize { get; set; } = 2;
        /// <summary>从 LOCALIZED 降级到 RECOGNIZED 的连续丢帧阈值。</summary>
        [Obsolete("Shared C++ Session degradation uses monotonic time, not frame counts.")]
        public int GracefulDegradeThreshold { get; set; } = 4;
        /// <summary>触发 Reset 回退 Raw 的连续丢帧阈值。</summary>
        [Obsolete("Shared C++ Session expiry uses monotonic time, not frame counts.")]
        public int FullResetThreshold { get; set; } = 8;

        private NativeSessionBridge _session;
        private ulong _sessionMaxResultAgeNs;
        private LocalizationTrackingMetadata? _lastSubmittedTrackingMetadata;
        private int _consecutiveLostFrames; // Raw diagnostic count only; never a policy input.

        public AreaTargetTracker()
        {
            _loader = new AssetBundleLoader();
            _diagnosticBuildVersion = Application.version ?? string.Empty;
            _diagnosticDeviceModel = SystemInfo.deviceModel ?? string.Empty;
            _diagnosticOperatingSystem = SystemInfo.operatingSystem ?? string.Empty;
        }

        /// <summary>Identifier attached to Runtime frames for the currently loaded map.</summary>
        public string MapId
        {
            get
            {
                string mapName = _loader?.Manifest?.name;
                return string.IsNullOrWhiteSpace(mapName) ? "unnamed-map" : mapName;
            }
        }

        /// <inheritdoc/>
        public bool Initialize(string assetPath)
        {
            if (_disposed)
            {
                Debug.LogError("[AreaTargetPlugin] Cannot initialize a disposed tracker.");
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.LifecycleFailure,
                    "Initialization was rejected because the tracker is disposed.");
                return false;
            }

            if (_initialized)
            {
                Debug.LogWarning("[AreaTargetPlugin] Tracker is already initialized; use a fresh tracker for another map.");
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.LifecycleFailure,
                    "Initialization was rejected because the tracker is already initialized; use a fresh tracker for another map.");
                return false;
            }

            ResetDiagnosticMapIdentity();
            bool success = _loader.Load(assetPath);
            if (!success)
            {
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.MapLoadFailed,
                    "Map package could not be loaded.");
                return false;
            }

            UpdateDiagnosticMapIdentity(assetPath);

            // Load the feature database from the asset bundle
            _featureDb = new FeatureDatabaseReader();
            if (!_featureDb.Load(_loader.FeatureDbPath))
            {
                Debug.LogError("[AreaTargetPlugin] Failed to load feature database.");
                _featureDb = null;
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.SqliteFailed,
                    "Feature database could not be loaded.");
                return false;
            }

            // Initialize the visual localization engine
            _localizationEngine = new VisualLocalizationEngine();
            if (!_localizationEngine.Initialize(_featureDb))
            {
                Debug.LogError("[AreaTargetPlugin] Failed to initialize localization engine.");
                _localizationEngine.Dispose();
                _localizationEngine = null;
                _featureDb.Dispose();
                _featureDb = null;
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.NativeInitializationFailed,
                    "Native localization engine could not be initialized.");
                return false;
            }

            // Validate both APIs before starting the worker, so a missing Session
            // export cannot leak an already-running raw engine.
            try { using (var validatedSession = new NativeSessionBridge()) { } }
            catch (Exception ex)
            {
                _localizationEngine.Dispose(); _localizationEngine = null;
                _featureDb.Dispose(); _featureDb = null;
                RecordLifecycleDiagnostic(LocalizationFailureCategory.NativeInitializationFailed, ex.Message);
                return false;
            }
            _lastSubmittedTrackingMetadata = null;
            _localizationRunner = new AsyncLocalizationRunner(_localizationEngine);
            _localizationRunner.ResultProduced += RecordWorkerFrameDiagnostic;
            if (!_localizationRunner.Start())
            {
                _localizationRunner.ResultProduced -= RecordWorkerFrameDiagnostic;
                Debug.LogError("[AreaTargetPlugin] Failed to start localization worker.");
                _localizationEngine.Dispose();
                _localizationEngine = null;
                _featureDb.Dispose();
                _featureDb = null;
                RecordLifecycleDiagnostic(
                    LocalizationFailureCategory.LifecycleFailure,
                    "Localization worker could not be started.");
                return false;
            }

            _initialized = true;
            _state = TrackingState.INITIALIZING;
            _lastNativeDebugInfo = default;
            RecordLifecycleDiagnostic(
                LocalizationFailureCategory.None,
                "Map loaded and localization worker started.");
            Debug.Log("[AreaTargetPlugin] Tracker initialized successfully.");
            return true;
        }

        /// <inheritdoc/>
        /// <remarks>
        /// Legacy non-blocking adapter. It submits a frame and consumes an already
        /// completed result if one is available; it never invokes native code on the
        /// Unity caller thread.
        /// </remarks>
        public TrackingResult ProcessFrame(CameraFrame cameraFrame)
        {
            if (!SubmitFrame(cameraFrame))
                return CreateLostTrackingResult();

            return TryGetLatestTrackingResult(
                GetMonotonicTimestampNs(), DefaultMaxResultAgeNs, out TrackingResult result)
                ? result
                : CreateLostTrackingResult();
        }

        /// <summary>
        /// Processes one immutable Runtime frame. Native PnP output is T_C_S; this
        /// tracker returns only T_U_S to downstream scene code.
        /// </summary>
        public TrackingResult ProcessFrame(LocalizationFrame localizationFrame)
        {
            if (!SubmitFrame(localizationFrame))
                return CreateLostTrackingResult();

            return TryGetLatestTrackingResult(
                GetMonotonicTimestampNs(), DefaultMaxResultAgeNs, out TrackingResult result)
                ? result
                : CreateLostTrackingResult();
        }

        /// <inheritdoc/>
        public bool SubmitFrame(CameraFrame cameraFrame)
        {
            if (!_initialized || _disposed)
            {
                RecordDiagnostic(
                    cameraFrame.FrameId,
                    cameraFrame.CaptureTimestampNs,
                    0,
                    0,
                    0,
                    0,
                    _state,
                    LocalizationQuality.NONE,
                    0f,
                    false,
                    LocalizationFailureCategory.LifecycleFailure,
                    "Frame was rejected because the tracker is not initialized.",
                    default);
                return false;
            }

            if (string.IsNullOrWhiteSpace(cameraFrame.MapId))
                cameraFrame.MapId = MapId;
            if (!cameraFrame.TryCreateLocalizationFrame(
                    out LocalizationFrame localizationFrame,
                    out _))
            {
                RecordDiagnostic(
                    cameraFrame.FrameId,
                    cameraFrame.CaptureTimestampNs,
                    _localizationRunner?.CurrentGeneration ?? 0,
                    _localizationRunner?.OverwrittenPendingFrames ?? 0,
                    0,
                    0,
                    _state,
                    LocalizationQuality.NONE,
                    0f,
                    false,
                    LocalizationFailureCategory.InvalidFrame,
                    "Frame payload was invalid.",
                    default);
                return false;
            }

            return SubmitFrame(localizationFrame);
        }

        /// <inheritdoc/>
        public bool SubmitFrame(LocalizationFrame localizationFrame)
        {
            if (!_initialized || _disposed || _localizationRunner == null)
            {
                RecordDiagnostic(
                    localizationFrame.FrameId,
                    localizationFrame.CaptureTimestampNs,
                    0,
                    0,
                    0,
                    0,
                    _state,
                    LocalizationQuality.NONE,
                    0f,
                    false,
                    LocalizationFailureCategory.LifecycleFailure,
                    "Frame was rejected because the tracker is not initialized.",
                    default);
                return false;
            }
            if (!string.Equals(localizationFrame.MapId, MapId, StringComparison.Ordinal))
            {
                RecordDiagnostic(
                    localizationFrame.FrameId,
                    localizationFrame.CaptureTimestampNs,
                    _localizationRunner.CurrentGeneration,
                    _localizationRunner.OverwrittenPendingFrames,
                    0,
                    0,
                    _state,
                    LocalizationQuality.NONE,
                    0f,
                    false,
                    LocalizationFailureCategory.InvalidFrame,
                    "Frame map identity does not match the active map.",
                    default);
                return false;
            }

            var metadata = localizationFrame.TrackingMetadata;
            if (_lastSubmittedTrackingMetadata.HasValue)
            {
                var previous = _lastSubmittedTrackingMetadata.Value;
                if (previous.CameraId != metadata.CameraId
                    || previous.CaptureClockEpoch != metadata.CaptureClockEpoch
                    || previous.TrackingEpoch != metadata.TrackingEpoch
                    || (previous.TrackingQuality == 2 && metadata.TrackingQuality != 2))
                {
                    // Host lifecycle identity changed. In-flight raw work is invalidated
                    // by the runner generation; C++ alignment is reset, never copied.
                    ResetAsync();
                    _lastSubmittedTrackingMetadata = metadata;
                    return false;
                }
            }
            _lastSubmittedTrackingMetadata = metadata;

            long overwrittenBefore = _localizationRunner.OverwrittenPendingFrames;
            bool accepted = _localizationRunner.Submit(localizationFrame);
            long overwrittenAfter = _localizationRunner.OverwrittenPendingFrames;
            long generation = _localizationRunner.CurrentGeneration;

            RecordDiagnostic(
                localizationFrame.FrameId,
                localizationFrame.CaptureTimestampNs,
                generation,
                overwrittenAfter,
                0,
                0,
                _state,
                LocalizationQuality.NONE,
                0f,
                false,
                accepted ? LocalizationFailureCategory.None : LocalizationFailureCategory.LifecycleFailure,
                accepted ? "Frame submitted to localization worker." : "Localization worker rejected the frame.",
                default);

            if (accepted && overwrittenAfter > overwrittenBefore)
            {
                RecordDiagnostic(
                    localizationFrame.FrameId,
                    localizationFrame.CaptureTimestampNs,
                    generation,
                    overwrittenAfter,
                    0,
                    0,
                    _state,
                    LocalizationQuality.NONE,
                    0f,
                    false,
                    LocalizationFailureCategory.None,
                    "Latest pending frame overwrote an older pending frame.",
                    default);
            }

            return accepted;
        }

        /// <inheritdoc/>
        public bool TryGetLatestTrackingResult(
            long nowTimestampNs,
            long maxAgeNs,
            out TrackingResult result)
        {
            result = CreateLostTrackingResult();
            if (!_initialized || _disposed || _localizationRunner == null) return false;
            ulong requestedAge = checked((ulong)(maxAgeNs > 0 ? maxAgeNs : DefaultMaxResultAgeNs));
            if (_session != null && _sessionMaxResultAgeNs != requestedAge)
            {
                // An explicit configuration change invalidates lifecycle work and
                // requires fresh confirmation; no measurement is silently reprofiled.
                ResetAsync();
                RecordLifecycleDiagnostic(LocalizationFailureCategory.None,
                    "Session maximum result age changed; alignment and in-flight work reset.");
            }
            if (_session == null) _session = CreateSession((long)requestedAge);
            if (_localizationRunner.TryTakeLatestForSession(out LocalizationFrameResult frameResult))
            {
                result = ApplyFrameResultAt(frameResult, nowTimestampNs);
                RecordFrameResultDiagnostic(frameResult, result, nowTimestampNs);
            }
            else
            {
                // A real timer poll, not a fake failed visual frame. Core owns expiry.
                result = _session.Poll(nowTimestampNs);
                _state = result.State;
            }
            return true;
        }

        internal TrackingResult ApplyFrameResultAt(LocalizationFrameResult frameResult, long nowTimestampNs)
        {
            if (_session == null) _session = CreateSession(DefaultMaxResultAgeNs);
            _lastNativeDebugInfo = frameResult.NativeDebugInfo;
            _consecutiveLostFrames = frameResult.IsSuccess ? 0 : _consecutiveLostFrames + 1;
            TrackingResult result = _session.Update(frameResult, nowTimestampNs);
            _state = result.State;
            return result;
        }

        private NativeSessionBridge CreateSession(long maxAgeNs)
        {
            var config = NativeSessionBridge.DefaultConfig();
            config.MaxResultAgeNs = checked((ulong)(maxAgeNs > 0 ? maxAgeNs : DefaultMaxResultAgeNs));
            var session = new NativeSessionBridge(config);
            _sessionMaxResultAgeNs = config.MaxResultAgeNs;
            RecordLifecycleDiagnostic(LocalizationFailureCategory.None,
                $"Effective native Session profile: window={config.WindowSize}, init={config.InitializationSamples}, " +
                $"recovery={config.RecoverySamples}, residual={config.MaxTranslationResidualM}m/{config.MaxRotationResidualRad}rad, " +
                $"resultAge={config.MaxResultAgeNs}ns, hold={config.MaxAlignmentAgeNs}ns, skew={config.MaxPoseSkewNs}ns, tau={config.SmoothingTauSeconds}s.");
            return session;
        }

        private static TrackingResult CreateLostTrackingResult()
        {
            return new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0,
                Quality = LocalizationQuality.NONE
            };
        }

        private static TrackingResult ToTrackingResult(LocalizationFrameResult frameResult)
        {
            return new TrackingResult
            {
                State = frameResult.State,
                Pose = frameResult.UnityWorldFromScan ?? Matrix4x4.identity,
                Confidence = frameResult.Confidence,
                MatchedFeatures = frameResult.MatchedFeatures,
                Quality = frameResult.Quality
            };
        }

        /// <summary>
        /// Clears main-thread tracking state and schedules the native reset on the
        /// runner's worker. No Unity caller directly resets a native handle.
        /// </summary>
        private void ClearManagedTrackingState()
        {
            _session?.Dispose();
            _session = null;
            _sessionMaxResultAgeNs = 0;
            _lastSubmittedTrackingMetadata = null;
            _consecutiveLostFrames = 0;
            _lastNativeDebugInfo = default;
        }

        /// <inheritdoc/>
        public TrackingState GetTrackingState()
        {
            return _state;
        }

        /// <inheritdoc/>
        /// <remarks>
        /// Clears the shared Session and resets the worker-owned raw localizer,
        /// and restarts localization from scratch.
        /// Validates: Requirements 7.1, 7.2, 7.3, 14.4
        /// </remarks>
        public void Reset()
        {
            ResetAsync();
        }

        /// <inheritdoc/>
        public Task ResetAsync()
        {
            if (_disposed)
                return Task.FromResult(true);

            RecordLifecycleDiagnostic(
                LocalizationFailureCategory.None,
                "Reset requested.");
            _state = TrackingState.INITIALIZING;
            ClearManagedTrackingState();
            Debug.Log("[AreaTargetPlugin] Tracker reset.");

            return _localizationRunner == null
                ? Task.FromResult(true)
                : _localizationRunner.ResetAsync();
        }

        /// <summary>
        /// Returns debug diagnostics from the last processed frame's native pipeline.
        /// </summary>
        internal VLDebugInfo GetDebugInfo()
        {
            return _lastNativeDebugInfo;
        }

        /// <summary>
        /// 返回扩展调试信息，包含 C# 端状态和 native 端 debug 信息。
        /// </summary>
        public ExtendedDebugInfo GetExtendedDebugInfo()
        {
            LocalizationDiagnosticRecord lastDiagnostic;
            lock (_diagnosticStateGate)
            {
                lastDiagnostic = _lastDiagnosticRecord;
            }

            return new ExtendedDebugInfo
            {
                CurrentMode = _session != null && _session.LastNativeResult.AlignmentValid != 0
                    ? LocalizationMode.Aligned : LocalizationMode.Raw,
                IsATSet = _session != null && _session.LastNativeResult.AlignmentValid != 0,
                PoseBufferFrameCount = 0, // Legacy managed buffers no longer exist.
                ConsecutiveLostFrames = _consecutiveLostFrames,
                SlidingWindowFrameCount = 0, // Window is owned by C++ Session.
                LastDiagnosticFrameId = lastDiagnostic?.FrameId ?? -1,
                LastCaptureTimestampNs = lastDiagnostic?.CaptureTimestampNs ?? 0,
                LastDiagnosticState = lastDiagnostic?.State ?? TrackingState.INITIALIZING,
                LastDiagnosticQuality = lastDiagnostic?.Quality ?? LocalizationQuality.NONE,
                LastResultAgeNs = lastDiagnostic?.ResultAgeNs ?? 0,
                LastWorkerProcessingTimeNs = lastDiagnostic?.WorkerProcessingTimeNs ?? 0,
                LastFailureCategory = lastDiagnostic?.FailureCategory ?? LocalizationFailureCategory.None,
                LastFailureReason = lastDiagnostic?.FailureReason ?? string.Empty,
                DiagnosticDroppedRecordCount = _diagnosticBuffer.DroppedRecordCount,
                NativeDebugInfo = _lastNativeDebugInfo
            };
        }

        /// <summary>Returns an immutable snapshot of the bounded, image-free diagnostics.</summary>
        public IReadOnlyList<LocalizationDiagnosticRecord> GetDiagnosticSnapshot()
        {
            return _diagnosticBuffer.Snapshot();
        }

        /// <summary>Exports the current bounded diagnostic snapshot as JSON Lines.</summary>
        public bool TryExportDiagnostics(
            out string outputPath,
            out LocalizationFailureCategory failureCategory,
            out string failureReason)
        {
            return new LocalizationDiagnosticExporter().TryExport(
                GetDiagnosticSnapshot(),
                out outputPath,
                out failureCategory,
                out failureReason);
        }

        /// <inheritdoc/>
        /// <remarks>
        /// Releases all resources: localization engine, feature database,
        /// asset loader, and shared native Session.
        /// Validates: Requirements 14.5
        /// </remarks>
        public void Dispose()
        {
            DisposeAsync();
        }

        /// <inheritdoc/>
        public Task DisposeAsync()
        {
            if (_disposeTask != null)
                return _disposeTask;

            RecordLifecycleDiagnostic(
                LocalizationFailureCategory.None,
                "Dispose requested.");
            _disposed = true;
            _initialized = false;
            _state = TrackingState.LOST;
            ClearManagedTrackingState();

            AsyncLocalizationRunner runner = _localizationRunner;
            _localizationRunner = null;
            if (runner != null)
                runner.ResultProduced -= RecordWorkerFrameDiagnostic;
            _disposeTask = DisposeCoreAsync(runner);
            return _disposeTask;
        }

        private async Task DisposeCoreAsync(AsyncLocalizationRunner runner)
        {
            try
            {
                if (runner != null)
                    await runner.DisposeAsync();
                else
                    _localizationEngine?.Dispose();
            }
            finally
            {
                _localizationEngine = null;
                _featureDb?.Dispose();
                _featureDb = null;
                _loader = null;
                ClearManagedTrackingState();
                _state = TrackingState.LOST;
                Debug.Log("[AreaTargetPlugin] Tracker disposed.");
            }
        }

        private void RecordFrameResultDiagnostic(
            LocalizationFrameResult frameResult,
            TrackingResult trackingResult,
            long nowTimestampNs)
        {
            LocalizationFailureCategory category = frameResult.FailureCategory;
            string reason;

            if (frameResult.NativeDebugInfo.consistency_rejected == 1)
            {
                category = LocalizationFailureCategory.LocalizationFailed;
                reason = "Localization result failed consistency checks.";
            }
            else if (category != LocalizationFailureCategory.None)
            {
                reason = "Native localization did not return a valid pose.";
            }
            else if (trackingResult.State == TrackingState.TRACKING)
            {
                reason = "Localization result was applied.";
            }
            else
            {
                category = LocalizationFailureCategory.LocalizationFailed;
                reason = "Localization result was not applied.";
            }

            RecordDiagnostic(
                frameResult.FrameId,
                frameResult.CaptureTimestampNs,
                frameResult.MapGeneration,
                _localizationRunner?.OverwrittenPendingFrames ?? 0,
                GetResultAgeNs(nowTimestampNs, frameResult.CaptureTimestampNs),
                frameResult.WorkerProcessingTimeNs,
                trackingResult.State,
                trackingResult.Quality,
                trackingResult.Confidence,
                trackingResult.State == TrackingState.TRACKING && frameResult.UnityWorldFromScan.HasValue,
                category,
                reason,
                frameResult.NativeDebugInfo);
        }

        /// <summary>
        /// Records the worker-owned native outcome before a Unity scene consumes it.
        /// This callback only writes immutable scalars into the thread-safe buffer;
        /// it never touches scene state, transforms, or Unity logging APIs.
        /// </summary>
        private void RecordWorkerFrameDiagnostic(LocalizationFrameResult frameResult)
        {
            LocalizationFailureCategory category = frameResult.FailureCategory;
            string reason = category == LocalizationFailureCategory.None
                ? "Native localization result was produced."
                : "Native localization did not return a valid pose.";

            RecordDiagnostic(
                frameResult.FrameId,
                frameResult.CaptureTimestampNs,
                frameResult.MapGeneration,
                _localizationRunner?.OverwrittenPendingFrames ?? 0,
                0,
                frameResult.WorkerProcessingTimeNs,
                frameResult.State,
                frameResult.Quality,
                frameResult.Confidence,
                false,
                category,
                reason,
                frameResult.NativeDebugInfo);
        }

        private void RecordLifecycleDiagnostic(
            LocalizationFailureCategory failureCategory,
            string failureReason)
        {
            RecordDiagnostic(
                -1,
                0,
                _localizationRunner?.CurrentGeneration ?? 0,
                _localizationRunner?.OverwrittenPendingFrames ?? 0,
                0,
                0,
                _state,
                LocalizationQuality.NONE,
                0f,
                false,
                failureCategory,
                failureReason,
                _lastNativeDebugInfo);
        }

        private void RecordDiagnostic(
            long frameId,
            long captureTimestampNs,
            long mapGeneration,
            long overwrittenPendingFrames,
            long resultAgeNs,
            long workerProcessingTimeNs,
            TrackingState state,
            LocalizationQuality quality,
            float confidence,
            bool poseApplied,
            LocalizationFailureCategory failureCategory,
            string failureReason,
            VLDebugInfo nativeDebugInfo)
        {
            var record = new LocalizationDiagnosticRecord(
                DateTime.UtcNow,
                _diagnosticBuildVersion,
                RuntimePackageVersion,
                _diagnosticMapId,
                _diagnosticMapVersion,
                _diagnosticMapHash,
                _diagnosticDeviceModel,
                _diagnosticOperatingSystem,
                frameId,
                captureTimestampNs,
                mapGeneration,
                overwrittenPendingFrames,
                resultAgeNs,
                workerProcessingTimeNs,
                state,
                quality,
                confidence,
                poseApplied,
                failureCategory,
                SanitizeDiagnosticReason(failureReason),
                nativeDebugInfo);

            _diagnosticBuffer.Add(record);
            lock (_diagnosticStateGate)
            {
                _lastDiagnosticRecord = record;
            }
        }

        private void ResetDiagnosticMapIdentity()
        {
            _diagnosticMapId = "map-unavailable";
            _diagnosticMapVersion = "unknown";
            _diagnosticMapHash = "unknown";
        }

        private void UpdateDiagnosticMapIdentity(string assetPath)
        {
            _diagnosticMapVersion = SanitizeDiagnosticIdentifier(
                _loader?.Manifest?.version,
                "unknown");
            _diagnosticMapHash = TryComputeManifestHash(assetPath);
            string mapHashPrefix = _diagnosticMapHash.Length > 12
                ? _diagnosticMapHash.Substring(0, 12)
                : _diagnosticMapHash;
            _diagnosticMapId = "map-" + mapHashPrefix;
        }

        private static string TryComputeManifestHash(string assetPath)
        {
            try
            {
                byte[] manifestBytes = File.ReadAllBytes(Path.Combine(assetPath, "manifest.json"));
                using (var sha256 = SHA256.Create())
                {
                    return BitConverter.ToString(sha256.ComputeHash(manifestBytes))
                        .Replace("-", string.Empty)
                        .ToLowerInvariant();
                }
            }
            catch (Exception)
            {
                return "unknown";
            }
        }

        private static string SanitizeDiagnosticIdentifier(string value, string fallback)
        {
            if (string.IsNullOrWhiteSpace(value))
                return fallback;

            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (!char.IsLetterOrDigit(character)
                    && character != '.'
                    && character != '-'
                    && character != '_')
                {
                    return fallback;
                }
            }

            return value;
        }

        private static string SanitizeDiagnosticReason(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return string.Empty;

            if (value.IndexOf('/') >= 0
                || value.IndexOf('\\') >= 0
                || value.IndexOf("ImageData", StringComparison.OrdinalIgnoreCase) >= 0
                || value.IndexOf("JPEG", StringComparison.OrdinalIgnoreCase) >= 0
                || value.IndexOf("ScanData", StringComparison.OrdinalIgnoreCase) >= 0
                || value.IndexOf("file://", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "Details were omitted by the diagnostic privacy policy.";
            }

            return value;
        }

        private static long GetResultAgeNs(long nowTimestampNs, long captureTimestampNs)
        {
            if (nowTimestampNs <= captureTimestampNs)
                return 0;

            return nowTimestampNs - captureTimestampNs;
        }

        private static long GetMonotonicTimestampNs()
        {
            long ticks = System.Diagnostics.Stopwatch.GetTimestamp();
            long frequency = System.Diagnostics.Stopwatch.Frequency;
            long seconds = ticks / frequency;
            long remainder = ticks % frequency;
            return seconds * 1000000000L + remainder * 1000000000L / frequency;
        }
    }
}
