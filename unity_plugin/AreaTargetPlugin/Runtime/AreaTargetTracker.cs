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
    /// Chains VisualLocalizationEngine → KalmanPoseFilter for smooth tracking.
    /// 
    /// 两阶段定位策略：
    /// 1. Raw Mode（冷启动）：ORB + AKAZE fallback，成功率优先
    /// 2. Aligned Mode（稳态）：已应用 AT，精度优先
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
        private KalmanPoseFilter _kalmanFilter;
        private FeatureDatabaseReader _featureDb;
        private bool _initialized;
        private bool _disposed;
        private Task _disposeTask;
        private LocalizationMode _currentMode = LocalizationMode.Raw;
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

        private const long DefaultMaxResultAgeNs = 1_000_000_000L;
        private const string RuntimePackageVersion = "1.3.0";

        // --- 可配置属性 (Requirements 5.4, 5.8, 6.6) ---
        /// <summary>触发首次 AT 计算的最小 Raw 模式成功帧数。</summary>
        public int AlignmentFrameThreshold { get; set; } = 10;
        /// <summary>Aligned 模式下 AT 刷新间隔（成功帧数）。</summary>
        public int ATRefreshInterval { get; set; } = 20;
        /// <summary>Aligned 模式滑动窗口大小。</summary>
        public int SlidingWindowSize { get; set; } = 30;
        /// <summary>从 LOCALIZED 降级到 RECOGNIZED 的连续丢帧阈值。</summary>
        public int GracefulDegradeThreshold { get; set; } = 4;
        /// <summary>触发 Reset 回退 Raw 的连续丢帧阈值。</summary>
        public int FullResetThreshold { get; set; } = 8;

        // --- 内部状态 ---
        private List<LocalizationFramePair> _rawPoseBuffer = new List<LocalizationFramePair>();
        private List<LocalizationFramePair> _slidingWindow = new List<LocalizationFramePair>();
        private int _consecutiveLostFrames;
        private int _framesSinceLastATRefresh;
        private Matrix4x4? _currentAT;

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

            // Initialize the Kalman pose filter for smoothing
            _kalmanFilter = new KalmanPoseFilter();

            _initialized = true;
            _state = TrackingState.INITIALIZING;
            _currentMode = LocalizationMode.Raw;
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
            if (!_initialized || _disposed || _localizationRunner == null)
                return false;

            if (!_localizationRunner.TryDequeueLatest(
                MapId,
                _localizationRunner.CurrentGeneration,
                nowTimestampNs,
                maxAgeNs,
                out LocalizationFrameResult frameResult))
            {
                if (_localizationRunner.TryTakeLatestRejection(
                        out LocalizationFrameResult rejectedResult,
                        out _))
                {
                    RecordDiagnostic(
                        rejectedResult.FrameId,
                        rejectedResult.CaptureTimestampNs,
                        rejectedResult.MapGeneration,
                        _localizationRunner.OverwrittenPendingFrames,
                        GetResultAgeNs(nowTimestampNs, rejectedResult.CaptureTimestampNs),
                        rejectedResult.WorkerProcessingTimeNs,
                        rejectedResult.State,
                        rejectedResult.Quality,
                        rejectedResult.Confidence,
                        false,
                        LocalizationFailureCategory.StaleResult,
                        "Localization result was rejected by age, map generation, or frame order.",
                        rejectedResult.NativeDebugInfo);
                }
                return false;
            }

            result = ApplyFrameResult(frameResult);
            RecordFrameResultDiagnostic(frameResult, result, nowTimestampNs);
            return true;
        }

        /// <summary>
        /// Applies a result that has already been validated by the runner. This code
        /// remains on Unity's main thread and never reads a native handle directly.
        /// </summary>
        private TrackingResult ApplyFrameResult(LocalizationFrameResult frameResult)
        {
            TrackingResult locResult = ToTrackingResult(frameResult);
            _lastNativeDebugInfo = frameResult.NativeDebugInfo;

            // Step 2: 获取 debug 信息进行一致性检查 (Req 6.1, 6.2)
            VLDebugInfo debugInfo = frameResult.NativeDebugInfo;

            // Step 3: 一致性过滤 — consistency_rejected == 1 时标记 LOST，丢弃位姿
            if (debugInfo.consistency_rejected == 1)
            {
                _consecutiveLostFrames++;
                _state = TrackingState.LOST;
                return new TrackingResult
                {
                    State = TrackingState.LOST,
                    Pose = Matrix4x4.identity,
                    Confidence = 0f,
                    MatchedFeatures = 0,
                    Quality = LocalizationQuality.NONE
                };
            }

            // Step 4: 定位成功
            if (frameResult.IsSuccess)
            {
                _consecutiveLostFrames = 0;
                var framePair = new LocalizationFramePair(
                    frameResult.UnityWorldFromCamera,
                    frameResult.CameraFromScan.Value);

                if (_currentMode == LocalizationMode.Raw)
                {
                    return ProcessRawModeSuccess(locResult, framePair);
                }
                else // Aligned mode
                {
                    return ProcessAlignedModeSuccess(locResult, framePair);
                }
            }

            // Step 5: 定位失败（非一致性拒绝）
            _consecutiveLostFrames++;

            if (_currentMode == LocalizationMode.Aligned)
            {
                return ProcessAlignedModeLost(locResult);
            }

            // Raw 模式丢帧：保持 LOST，不触发 Reset (Req 6.7)
            _state = TrackingState.LOST;
            return new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = locResult.Confidence,
                MatchedFeatures = locResult.MatchedFeatures,
                Quality = LocalizationQuality.NONE
            };
        }

        /// <summary>
        /// Raw 模式定位成功：位姿缓冲 → AT 触发 (Req 5.1, 5.2, 5.3, 5.5)
        /// </summary>
        private TrackingResult ProcessRawModeSuccess(
            TrackingResult locResult,
            LocalizationFramePair framePair)
        {
            // 添加完整成功帧对，而不是裸 T_C_S 位姿。
            _rawPoseBuffer.Add(framePair);

            // 检查是否达到 AT 计算阈值
            if (_rawPoseBuffer.Count >= AlignmentFrameThreshold)
            {
                if (AlignmentTransformCalculator.TryCompute(_rawPoseBuffer, out Matrix4x4 at))
                {
                    // AT 计算成功 → 设置 AT 并切换到 Aligned 模式
                    _localizationRunner?.SetAlignmentTransformAsync(at);
                    _currentMode = LocalizationMode.Aligned;
                    _currentAT = at;
                    _rawPoseBuffer.Clear();
                    _framesSinceLastATRefresh = 0;
                }
                // AT 计算失败 → 保持 Raw 模式继续积累
            }

            // Kalman 滤波
            Matrix4x4 smoothedPose = _kalmanFilter.Update(locResult.Pose);
            _state = TrackingState.TRACKING;

            return new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = smoothedPose,
                Confidence = locResult.Confidence,
                MatchedFeatures = locResult.MatchedFeatures,
                Quality = LocalizationQuality.RECOGNIZED
            };
        }

        /// <summary>
        /// Aligned 模式定位成功：滑动窗口 + AT 持续优化 (Req 5.6, 5.7, 5.9)
        /// </summary>
        private TrackingResult ProcessAlignedModeSuccess(
            TrackingResult locResult,
            LocalizationFramePair framePair)
        {
            // 添加完整成功帧对，而不是裸 T_C_S 位姿。
            _slidingWindow.Add(framePair);
            // 超出窗口大小时移除最旧帧
            while (_slidingWindow.Count > SlidingWindowSize)
            {
                _slidingWindow.RemoveAt(0);
            }

            // AT 持续优化：每 ATRefreshInterval 帧重新计算
            _framesSinceLastATRefresh++;
            if (_framesSinceLastATRefresh >= ATRefreshInterval)
            {
                if (AlignmentTransformCalculator.TryCompute(_slidingWindow, out Matrix4x4 newAT))
                {
                    // 安全阀检查：旋转 > 5° 或平移 > 0.5m 时丢弃
                    if (_currentAT.HasValue)
                    {
                        var (rotDeg, transM) = AlignmentTransformCalculator.ComputeDifference(
                            _currentAT.Value, newAT);

                        if (rotDeg > 5f || transM > 0.5f)
                        {
                            Debug.LogWarning(
                                $"[AreaTargetPlugin] AT 安全阀触发：旋转差 {rotDeg:F2}° 平移差 {transM:F4}m，丢弃新 AT");
                        }
                        else
                        {
                            // 安全范围内 → 更新 AT
                            _localizationRunner?.SetAlignmentTransformAsync(newAT);
                            _currentMode = LocalizationMode.Aligned;
                            _currentAT = newAT;
                        }
                    }
                    else
                    {
                        // 首次设置（理论上不应走到这里，但防御性处理）
                        _localizationRunner?.SetAlignmentTransformAsync(newAT);
                        _currentMode = LocalizationMode.Aligned;
                        _currentAT = newAT;
                    }
                }
                _framesSinceLastATRefresh = 0;
            }

            // Kalman 滤波
            Matrix4x4 smoothedPose = _kalmanFilter.Update(locResult.Pose);
            _state = TrackingState.TRACKING;

            return new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = smoothedPose,
                Confidence = locResult.Confidence,
                MatchedFeatures = locResult.MatchedFeatures,
                Quality = LocalizationQuality.LOCALIZED
            };
        }

        /// <summary>
        /// Aligned 模式丢帧：分级降级策略 (Req 6.3, 6.4, 6.5)
        /// </summary>
        private TrackingResult ProcessAlignedModeLost(TrackingResult locResult)
        {
            if (_consecutiveLostFrames < GracefulDegradeThreshold)
            {
                // Grace period (1 to GracefulDegradeThreshold-1)：Kalman 预测，Quality = LOCALIZED
                // KalmanPoseFilter 没有 Predict() 方法，使用最后的平滑位姿
                // 通过不调用 Update 来保持上一帧的平滑位姿
                Matrix4x4 lastPose = _kalmanFilter.IsInitialized
                    ? KalmanPoseFilter.StateToPose(KalmanPoseFilter.PoseToState(locResult.Pose))
                    : locResult.Pose;

                // 使用 Kalman filter 的当前状态作为预测
                // 由于没有 Predict()，我们用上一次 Update 的结果
                _state = TrackingState.TRACKING;
                return new TrackingResult
                {
                    State = TrackingState.TRACKING,
                    Pose = lastPose,
                    Confidence = locResult.Confidence,
                    MatchedFeatures = 0,
                    Quality = LocalizationQuality.LOCALIZED
                };
            }
            else if (_consecutiveLostFrames <= FullResetThreshold)
            {
                // 降级阶段 (GracefulDegradeThreshold to FullResetThreshold)：
                // Quality = RECOGNIZED，保留 AT
                _state = TrackingState.TRACKING;
                return new TrackingResult
                {
                    State = TrackingState.TRACKING,
                    Pose = locResult.Pose,
                    Confidence = locResult.Confidence,
                    MatchedFeatures = 0,
                    Quality = LocalizationQuality.RECOGNIZED
                };
            }
            else
            {
                // 完全重置 (> FullResetThreshold)：Reset → Raw 模式
                PerformInternalReset();
                _state = TrackingState.LOST;
                return new TrackingResult
                {
                    State = TrackingState.LOST,
                    Pose = locResult.Pose,
                    Confidence = 0f,
                    MatchedFeatures = 0,
                    Quality = LocalizationQuality.NONE
                };
            }
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
        private void PerformInternalReset()
        {
            RecordLifecycleDiagnostic(
                LocalizationFailureCategory.LocalizationFailed,
                "Automatic reset was requested after sustained localization loss.");
            ClearManagedTrackingState();
            if (_localizationRunner != null)
                _localizationRunner.ResetAsync();
        }

        private void ClearManagedTrackingState()
        {
            _rawPoseBuffer.Clear();
            _slidingWindow.Clear();
            _consecutiveLostFrames = 0;
            _framesSinceLastATRefresh = 0;
            _currentAT = null;
            _currentMode = LocalizationMode.Raw;
            _lastNativeDebugInfo = default;
            _kalmanFilter?.Reset();
        }

        /// <inheritdoc/>
        public TrackingState GetTrackingState()
        {
            return _state;
        }

        /// <inheritdoc/>
        /// <remarks>
        /// Clears tracking state, resets the Kalman filter and localization engine,
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
                CurrentMode = _currentMode,
                IsATSet = _currentAT.HasValue,
                PoseBufferFrameCount = _rawPoseBuffer.Count,
                ConsecutiveLostFrames = _consecutiveLostFrames,
                SlidingWindowFrameCount = _slidingWindow.Count,
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
        /// asset loader, and Kalman filter.
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
                _kalmanFilter = null;
                _rawPoseBuffer.Clear();
                _slidingWindow.Clear();
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
