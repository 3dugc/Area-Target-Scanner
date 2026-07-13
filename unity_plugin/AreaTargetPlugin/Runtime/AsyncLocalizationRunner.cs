using System;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Internal boundary around the native localizer. An implementation is owned by
    /// exactly one <see cref="AsyncLocalizationRunner"/> while it is running.
    /// </summary>
    internal interface ILocalizationProcessor : IDisposable
    {
        LocalizationFrameResult Process(LocalizationFrame frame, long generation);
        void SetAlignmentTransform(Matrix4x4 unityWorldFromScanAlignment);
        void Reset();
    }

    /// <summary>
    /// Owns a localization processor on one worker thread. The input side retains
    /// only the newest pending frame; Unity's main thread never invokes Process,
    /// Reset, or Dispose on the processor directly.
    /// </summary>
    internal sealed class AsyncLocalizationRunner
    {
        private readonly object _inputLock = new object();
        private readonly object _outputLock = new object();
        private readonly ILocalizationProcessor _processor;
        private readonly AutoResetEvent _workAvailable = new AutoResetEvent(false);

        private Thread _worker;
        private LocalizationFrame? _pendingFrame;
        private LocalizationFrame? _lastProcessorFrame;
        private long _lastProcessorGeneration;
        private Matrix4x4? _pendingAlignment;
        private LocalizationFrameResult? _latestResult;
        private TaskCompletionSource<bool> _resetCompletion;
        private TaskCompletionSource<bool> _alignmentCompletion;
        private TaskCompletionSource<bool> _disposeCompletion;

        private bool _started;
        private bool _acceptingFrames;
        private bool _resetRequested;
        private bool _resetInProgress;
        private bool _stopRequested;
        private bool _disposed;
        private long _generation;
        private long _overwrittenPendingFrames;
        private long _lastDeliveredFrameId = -1;
        private string _lastWorkerExceptionSummary;

        internal AsyncLocalizationRunner(ILocalizationProcessor processor)
        {
            _processor = processor ?? throw new ArgumentNullException(nameof(processor));
        }

        internal long OverwrittenPendingFrames
        {
            get
            {
                lock (_inputLock)
                {
                    return _overwrittenPendingFrames;
                }
            }
        }

        internal long CurrentGeneration
        {
            get
            {
                lock (_inputLock)
                {
                    return _generation;
                }
            }
        }

        internal string LastWorkerExceptionSummary
        {
            get
            {
                lock (_inputLock)
                {
                    return _lastWorkerExceptionSummary;
                }
            }
        }

        /// <summary>Starts the single worker once. Repeated calls return false.</summary>
        internal bool Start()
        {
            lock (_inputLock)
            {
                if (_started || _disposed)
                    return false;

                _started = true;
                _acceptingFrames = true;
                _worker = new Thread(WorkerLoop)
                {
                    IsBackground = true,
                    Name = "AreaTargetLocalizationWorker"
                };
                _worker.Start();
                return true;
            }
        }

        /// <summary>
        /// Copies the immutable frame into the runner-owned pending slot. If the
        /// worker is busy, the old pending frame is replaced instead of queued.
        /// </summary>
        internal bool Submit(LocalizationFrame frame)
        {
            LocalizationFrame copiedFrame = CopyFrame(frame);

            lock (_inputLock)
            {
                if (!_started || _disposed || _stopRequested || !_acceptingFrames)
                    return false;

                if (_pendingFrame.HasValue)
                    _overwrittenPendingFrames++;

                _pendingFrame = copiedFrame;
                _workAvailable.Set();
                return true;
            }
        }

        /// <summary>
        /// Returns and removes the newest result only when it belongs to the active
        /// map/generation, is not older than the configured age, and advances frame
        /// order. Rejected results are discarded so they cannot be applied later.
        /// </summary>
        internal bool TryDequeueLatest(
            string expectedMapId,
            long expectedGeneration,
            long nowTimestampNs,
            long maxAgeNs,
            out LocalizationFrameResult result)
        {
            result = default;
            if (string.IsNullOrWhiteSpace(expectedMapId)
                || expectedGeneration < 0
                || nowTimestampNs < 0
                || maxAgeNs < 0)
            {
                return false;
            }

            lock (_inputLock)
            {
                lock (_outputLock)
                {
                    if (!_latestResult.HasValue)
                        return false;

                    LocalizationFrameResult candidate = _latestResult.Value;
                    _latestResult = null;

                    long ageNs = nowTimestampNs - candidate.CaptureTimestampNs;
                    if (!string.Equals(candidate.MapId, expectedMapId, StringComparison.Ordinal)
                        || candidate.MapGeneration != expectedGeneration
                        || ageNs < 0
                        || ageNs > maxAgeNs
                        || candidate.FrameId <= _lastDeliveredFrameId)
                    {
                        return false;
                    }

                    _lastDeliveredFrameId = candidate.FrameId;
                    result = candidate;
                    return true;
                }
            }
        }

        /// <summary>
        /// Stops frame acceptance, drops queued data, waits for any active Process
        /// call to complete, then resets the processor on the worker itself.
        /// </summary>
        internal Task ResetAsync()
        {
            TaskCompletionSource<bool> alignmentCompletion;
            Task resetTask;

            lock (_inputLock)
            {
                if (_disposed || _stopRequested || !_started)
                    return Task.FromResult(true);

                if (_resetRequested || _resetInProgress)
                    return _resetCompletion.Task;

                _acceptingFrames = false;
                _generation++;
                _pendingFrame = null;
                _lastProcessorFrame = null;
                _pendingAlignment = null;
                alignmentCompletion = _alignmentCompletion;
                _alignmentCompletion = null;
                _lastDeliveredFrameId = -1;
                lock (_outputLock)
                {
                    _latestResult = null;
                }

                _resetCompletion = new TaskCompletionSource<bool>();
                resetTask = _resetCompletion.Task;
                _resetRequested = true;
                _workAvailable.Set();
            }

            alignmentCompletion?.TrySetCanceled();
            return resetTask;
        }

        /// <summary>
        /// Schedules the legacy native alignment hook on the same worker that owns
        /// frame processing. Newer commands replace an unprocessed alignment value.
        /// </summary>
        internal Task SetAlignmentTransformAsync(Matrix4x4 unityWorldFromScanAlignment)
        {
            CoordinateTransform.ValidateFiniteRigidTransform(
                unityWorldFromScanAlignment, nameof(unityWorldFromScanAlignment));

            lock (_inputLock)
            {
                if (_disposed || _stopRequested || !_started)
                    return Task.FromResult(true);

                _pendingAlignment = unityWorldFromScanAlignment;
                if (_alignmentCompletion == null)
                    _alignmentCompletion = new TaskCompletionSource<bool>();

                _workAvailable.Set();
                return _alignmentCompletion.Task;
            }
        }

        /// <summary>
        /// Stops the worker and disposes the processor only after no Process call can
        /// still use its native handle. Repeated calls return the same completion task.
        /// </summary>
        internal Task DisposeAsync()
        {
            TaskCompletionSource<bool> completion;
            TaskCompletionSource<bool> alignmentCompletion;
            bool disposeWithoutWorker = false;

            lock (_inputLock)
            {
                if (_disposeCompletion != null)
                    return _disposeCompletion.Task;

                _disposed = true;
                _acceptingFrames = false;
                _stopRequested = true;
                _pendingFrame = null;
                _pendingAlignment = null;
                alignmentCompletion = _alignmentCompletion;
                _alignmentCompletion = null;
                lock (_outputLock)
                {
                    _latestResult = null;
                }

                completion = new TaskCompletionSource<bool>();
                _disposeCompletion = completion;
                disposeWithoutWorker = !_started;
                if (!disposeWithoutWorker)
                    _workAvailable.Set();
            }

            if (disposeWithoutWorker)
            {
                try
                {
                    _processor.Dispose();
                    _workAvailable.Dispose();
                    completion.TrySetResult(true);
                }
                catch (Exception exception)
                {
                    completion.TrySetException(exception);
                }
            }

            alignmentCompletion?.TrySetCanceled();

            return completion.Task;
        }

        private void WorkerLoop()
        {
            try
            {
                while (true)
                {
                    _workAvailable.WaitOne();

                    while (true)
                    {
                        LocalizationFrame? frame = null;
                        Matrix4x4? alignment = null;
                        long generation = 0;
                        TaskCompletionSource<bool> resetCompletion = null;
                        TaskCompletionSource<bool> alignmentCompletion = null;

                        lock (_inputLock)
                        {
                            if (_stopRequested)
                                return;

                            if (_resetRequested)
                            {
                                _resetRequested = false;
                                _resetInProgress = true;
                                resetCompletion = _resetCompletion;
                            }
                            else if (_pendingAlignment.HasValue)
                            {
                                alignment = _pendingAlignment;
                                _pendingAlignment = null;
                                alignmentCompletion = _alignmentCompletion;
                                _alignmentCompletion = null;
                            }
                            else if (_pendingFrame.HasValue)
                            {
                                frame = _pendingFrame;
                                _pendingFrame = null;
                                generation = _generation;
                            }
                            else
                            {
                                break;
                            }
                        }

                        if (resetCompletion != null)
                        {
                            ResetProcessor(resetCompletion);
                            continue;
                        }

                        if (alignment.HasValue)
                        {
                            SetAlignmentTransform(alignment.Value, alignmentCompletion);
                            continue;
                        }

                        if (frame.HasValue)
                            ProcessFrame(frame.Value, generation);
                    }
                }
            }
            finally
            {
                FinalizeWorker();
            }
        }

        private void ProcessFrame(LocalizationFrame frame, long generation)
        {
            lock (_inputLock)
            {
                _lastProcessorFrame = frame;
                _lastProcessorGeneration = generation;
            }

            try
            {
                LocalizationFrameResult result = _processor.Process(frame, generation);
                PublishIfCurrent(result);
            }
            catch (Exception exception)
            {
                StopForWorkerFailure(frame, generation, exception);
            }
        }

        private void ResetProcessor(TaskCompletionSource<bool> completion)
        {
            try
            {
                _processor.Reset();
                lock (_inputLock)
                {
                    _resetInProgress = false;
                    _resetCompletion = null;
                    if (!_stopRequested)
                        _acceptingFrames = true;
                }
                completion.TrySetResult(true);
            }
            catch (Exception exception)
            {
                lock (_inputLock)
                {
                    _resetInProgress = false;
                    _resetCompletion = null;
                }
                StopForWorkerFailure(null, 0, exception);
                completion.TrySetException(exception);
            }
        }

        private void SetAlignmentTransform(
            Matrix4x4 unityWorldFromScanAlignment,
            TaskCompletionSource<bool> completion)
        {
            try
            {
                _processor.SetAlignmentTransform(unityWorldFromScanAlignment);
                completion?.TrySetResult(true);
            }
            catch (Exception exception)
            {
                StopForWorkerFailure(null, 0, exception);
                completion?.TrySetException(exception);
            }
        }

        private void PublishIfCurrent(LocalizationFrameResult result)
        {
            lock (_inputLock)
            {
                if (_stopRequested
                    || _resetRequested
                    || _resetInProgress
                    || result.MapGeneration != _generation)
                {
                    return;
                }

                lock (_outputLock)
                {
                    _latestResult = result;
                }
            }
        }

        private void StopForWorkerFailure(
            LocalizationFrame? failedFrame,
            long failedGeneration,
            Exception exception)
        {
            long failedAtNs = GetMonotonicTimestampNs();

            lock (_inputLock)
            {
                LocalizationFrame? frame = failedFrame ?? _lastProcessorFrame;
                long generation = failedFrame.HasValue
                    ? failedGeneration
                    : _lastProcessorGeneration;

                if (frame.HasValue
                    && generation == _generation
                    && !_resetRequested
                    && !_resetInProgress)
                {
                    LocalizationFrameResult failure = LocalizationFrameResult.Failed(
                        frame.Value,
                        generation,
                        failedAtNs,
                        failedAtNs,
                        LocalizationFailureCategory.LifecycleFailure,
                        default);
                    lock (_outputLock)
                    {
                        _latestResult = failure;
                    }
                }

                _lastWorkerExceptionSummary = exception.Message;
                _acceptingFrames = false;
                _stopRequested = true;
                _pendingFrame = null;
            }
        }

        private void FinalizeWorker()
        {
            TaskCompletionSource<bool> disposeCompletion;
            TaskCompletionSource<bool> resetCompletion;
            TaskCompletionSource<bool> alignmentCompletion;

            lock (_inputLock)
            {
                _disposed = true;
                _acceptingFrames = false;
                _stopRequested = true;
                _pendingFrame = null;
                _pendingAlignment = null;
                disposeCompletion = _disposeCompletion ?? new TaskCompletionSource<bool>();
                _disposeCompletion = disposeCompletion;
                resetCompletion = _resetCompletion;
                _resetCompletion = null;
                alignmentCompletion = _alignmentCompletion;
                _alignmentCompletion = null;
                _resetInProgress = false;
                lock (_outputLock)
                {
                    if (_latestResult.HasValue
                        && _latestResult.Value.FailureCategory != LocalizationFailureCategory.LifecycleFailure)
                    {
                        _latestResult = null;
                    }
                }
            }

            try
            {
                _processor.Dispose();
                _workAvailable.Dispose();
                disposeCompletion.TrySetResult(true);
            }
            catch (Exception exception)
            {
                disposeCompletion.TrySetException(exception);
            }
            finally
            {
                resetCompletion?.TrySetException(
                    new ObjectDisposedException(nameof(AsyncLocalizationRunner)));
                alignmentCompletion?.TrySetException(
                    new ObjectDisposedException(nameof(AsyncLocalizationRunner)));
            }
        }

        private static LocalizationFrame CopyFrame(LocalizationFrame source)
        {
            return new LocalizationFrame(
                source.FrameId,
                source.CaptureTimestampNs,
                source.GrayscaleImage,
                source.Width,
                source.Height,
                source.Intrinsics,
                source.Orientation,
                source.UnityWorldFromCamera,
                source.MapId);
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
