using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class AsyncLocalizationRunnerTests
    {
        [Test]
        public void PointCloudLocalizer_DelegatesNativeWorkToRunner()
        {
            string source = File.ReadAllText(Path.Combine(
                Application.dataPath,
                "..", "..", "unity_plugin", "AreaTargetPlugin", "Runtime", "PointCloudLocalizer.cs"));

            Assert.That(source, Does.Contain("AsyncLocalizationRunner"));
            Assert.That(source, Does.Contain("_runner.Submit("));
            Assert.That(source, Does.Not.Contain("_engine.ProcessFrame("));
            Assert.That(source, Does.Not.Contain("_engine?.Dispose("));
        }

        [Test]
        public async Task Submit_ReplacesPendingFrameWithNewestFrame()
        {
            var processor = new BlockingProcessor();
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(0, 100)), Is.True);
                await WaitFor(processor.WaitUntilStartedAsync(), "The worker did not start frame 0.");

                Assert.That(runner.Submit(CreateFrame(1, 101)), Is.True);
                Assert.That(runner.Submit(CreateFrame(2, 102)), Is.True);
                processor.Release();

                await WaitFor(processor.WaitUntilProcessedAsync(2), "The worker did not process the newest frame.");

                CollectionAssert.AreEqual(new long[] { 0, 2 }, processor.ProcessedFrameIds);
                Assert.That(runner.OverwrittenPendingFrames, Is.EqualTo(1));
            }
            finally
            {
                processor.Release();
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task Submit_UsesImmutableCopyOfFrameImage()
        {
            var processor = new BlockingProcessor { BlockProcess = false };
            var runner = new AsyncLocalizationRunner(processor);
            LocalizationFrame frame = CreateFrame(7, 100);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(frame), Is.True);

                byte[] callerCopy = frame.GrayscaleImage;
                callerCopy[0] = 99;

                await WaitFor(processor.WaitUntilProcessedAsync(7), "The worker did not process the frame.");
                Assert.That(processor.FirstImageByte, Is.EqualTo(7));
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task ResultProduced_PublishesWorkerOutcomeBeforeMainThreadConsumption()
        {
            var processor = new BlockingProcessor { BlockProcess = false };
            var runner = new AsyncLocalizationRunner(processor);
            var published = new TaskCompletionSource<LocalizationFrameResult>();
            runner.ResultProduced += result => published.TrySetResult(result);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(8, 100)), Is.True);

                await WaitFor(published.Task, "The worker did not publish its localization outcome.");
                LocalizationFrameResult result = await published.Task;
                Assert.That(result.FrameId, Is.EqualTo(8));
                Assert.That(result.FailureCategory, Is.EqualTo(LocalizationFailureCategory.None));
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task ResetAsync_WaitsForWorkerBeforeResettingProcessor()
        {
            var processor = new BlockingProcessor();
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(1, 100)), Is.True);
                await WaitFor(processor.WaitUntilStartedAsync(), "The worker did not begin processing.");

                Task reset = runner.ResetAsync();
                Assert.That(reset.IsCompleted, Is.False);
                Assert.That(processor.ResetCalled, Is.False);

                processor.Release();
                await WaitFor(reset, "ResetAsync did not finish after the worker completed.");

                Assert.That(processor.ResetCalled, Is.True);
                Assert.That(runner.CurrentGeneration, Is.EqualTo(1));
                Assert.That(runner.TryDequeueLatest("fixture-map", 0, 200, 100, out _), Is.False);
            }
            finally
            {
                processor.Release();
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task SetAlignmentTransformAsync_WaitsForWorkerBeforeCallingProcessor()
        {
            var processor = new BlockingProcessor();
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(1, 100)), Is.True);
                await WaitFor(processor.WaitUntilStartedAsync(), "The worker did not begin processing.");

                Task setAlignment = runner.SetAlignmentTransformAsync(Matrix4x4.identity);
                Assert.That(setAlignment.IsCompleted, Is.False);
                Assert.That(processor.SetAlignmentCalled, Is.False);

                processor.Release();
                await WaitFor(setAlignment, "The alignment command did not finish after processing.");

                Assert.That(processor.SetAlignmentCalled, Is.True);
            }
            finally
            {
                processor.Release();
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task TryDequeueLatest_RejectsMapMismatchStaleAndOutOfOrderResults()
        {
            var processor = new BlockingProcessor { BlockProcess = false };
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);

                Assert.That(runner.Submit(CreateFrame(3, 100)), Is.True);
                await WaitFor(processor.WaitUntilProcessedAsync(3), "The worker did not process frame 3.");
                Assert.That(runner.TryDequeueLatest("another-map", 0, 101, 100, out _), Is.False);

                Assert.That(runner.Submit(CreateFrame(4, 200)), Is.True);
                await WaitFor(processor.WaitUntilProcessedAsync(4), "The worker did not process frame 4.");
                Assert.That(runner.TryDequeueLatest("fixture-map", 0, 301, 100, out _), Is.False);

                Assert.That(runner.Submit(CreateFrame(5, 400)), Is.True);
                await WaitFor(processor.WaitUntilProcessedAsync(5), "The worker did not process frame 5.");
                Assert.That(runner.TryDequeueLatest("fixture-map", 0, 401, 100, out LocalizationFrameResult latest), Is.True);
                Assert.That(latest.FrameId, Is.EqualTo(5));

                Assert.That(runner.Submit(CreateFrame(4, 500)), Is.True);
                await WaitFor(processor.WaitUntilProcessedAsync(4, 2), "The worker did not process the out-of-order frame.");
                Assert.That(runner.TryDequeueLatest("fixture-map", 0, 501, 100, out _), Is.False);
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task TryDequeueLatest_WhenResultIsRejected_ExposesOneDiagnosticSummary()
        {
            var processor = new BlockingProcessor { BlockProcess = false };
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(6, 100)), Is.True);
                await WaitFor(processor.WaitUntilProcessedAsync(6), "The worker did not process frame 6.");

                Assert.That(runner.TryDequeueLatest("fixture-map", 0, 201, 100, out _), Is.False);
                Assert.That(
                    runner.TryTakeLatestRejection(
                        out LocalizationFrameResult rejected,
                        out string rejectionReason),
                    Is.True);
                Assert.That(rejected.FrameId, Is.EqualTo(6));
                Assert.That(rejectionReason, Does.Contain("stale"));
                Assert.That(runner.TryTakeLatestRejection(out _, out _), Is.False);
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task StartAndDisposeAsync_HavePredictableRepeatedLifecycleBehavior()
        {
            var processor = new BlockingProcessor { BlockProcess = false };
            var runner = new AsyncLocalizationRunner(processor);

            Assert.That(runner.Start(), Is.True);
            Assert.That(runner.Start(), Is.False);

            await runner.DisposeAsync();
            await runner.DisposeAsync();

            Assert.That(processor.DisposeCallCount, Is.EqualTo(1));
            Assert.That(runner.Submit(CreateFrame(9, 100)), Is.False);
        }

        [Test]
        public async Task WorkerException_IsPublishedAsLifecycleFailureAndStopsRunner()
        {
            var processor = new ThrowingProcessor();
            var runner = new AsyncLocalizationRunner(processor);
            var published = new TaskCompletionSource<LocalizationFrameResult>();
            runner.ResultProduced += result => published.TrySetResult(result);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(1, 100)), Is.True);
                await WaitFor(processor.ProcessAttempted.Task, "The worker did not attempt processing.");

                LocalizationFrameResult result = await WaitForLatest(
                    runner, "fixture-map", 0, 101, 100,
                    "The worker exception was not published as a result.");
                Assert.That(result.FailureCategory, Is.EqualTo(LocalizationFailureCategory.LifecycleFailure));
                await WaitFor(published.Task, "The worker failure was not published to diagnostics.");
                Assert.That(
                    (await published.Task).FailureCategory,
                    Is.EqualTo(LocalizationFailureCategory.LifecycleFailure));
                Assert.That(runner.Submit(CreateFrame(2, 200)), Is.False);
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        [Test]
        public async Task AlignmentWorkerException_IsPublishedAsLifecycleFailureAndStopsRunner()
        {
            var processor = new BlockingProcessor
            {
                BlockProcess = false,
                ThrowOnSetAlignment = true
            };
            var runner = new AsyncLocalizationRunner(processor);

            try
            {
                Assert.That(runner.Start(), Is.True);
                Assert.That(runner.Submit(CreateFrame(1, 100)), Is.True);
                await WaitFor(
                    processor.WaitUntilProcessedAsync(1),
                    "The worker did not process the fixture frame.");

                Task setAlignment = runner.SetAlignmentTransformAsync(Matrix4x4.identity);
                Task completed = await Task.WhenAny(
                    setAlignment,
                    Task.Delay(TimeSpan.FromSeconds(3)));
                Assert.That(
                    completed,
                    Is.SameAs(setAlignment),
                    "The worker did not finish the alignment command.");
                Assert.That(setAlignment.IsFaulted, Is.True);
                Assert.That(setAlignment.Exception?.GetBaseException(),
                    Is.TypeOf<InvalidOperationException>());

                LocalizationFrameResult result = await WaitForLatest(
                    runner, "fixture-map", 0, 101, 100,
                    "The alignment worker exception was not published as a result.");
                Assert.That(result.FailureCategory, Is.EqualTo(LocalizationFailureCategory.LifecycleFailure));
                Assert.That(runner.Submit(CreateFrame(2, 200)), Is.False);
            }
            finally
            {
                await runner.DisposeAsync();
            }
        }

        private static LocalizationFrame CreateFrame(long frameId, long timestampNs)
        {
            return new LocalizationFrame(
                frameId,
                timestampNs,
                new[] { (byte)frameId, (byte)1, (byte)2, (byte)3 },
                2,
                2,
                new Vector4(100f, 100f, 1f, 1f),
                ImageOrientation.LandscapeRight,
                Matrix4x4.identity,
                "fixture-map");
        }

        private static async Task WaitFor(Task task, string message)
        {
            Task completed = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(3)));
            Assert.That(completed, Is.SameAs(task), message);
            await task;
        }

        private static async Task<LocalizationFrameResult> WaitForLatest(
            AsyncLocalizationRunner runner,
            string mapId,
            long generation,
            long nowTimestampNs,
            long maxAgeNs,
            string timeoutMessage)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(3);
            while (DateTime.UtcNow < deadline)
            {
                if (runner.TryDequeueLatest(
                    mapId, generation, nowTimestampNs, maxAgeNs,
                    out LocalizationFrameResult result))
                {
                    return result;
                }

                await Task.Delay(5);
            }

            Assert.Fail(timeoutMessage);
            return default;
        }

        private sealed class BlockingProcessor : ILocalizationProcessor
        {
            private readonly object _gate = new object();
            private readonly ManualResetEventSlim _releaseGate = new ManualResetEventSlim(false);
            private readonly TaskCompletionSource<bool> _started = new TaskCompletionSource<bool>();
            private readonly Dictionary<long, int> _processedCounts = new Dictionary<long, int>();
            private readonly List<long> _processedFrameIds = new List<long>();

            public bool BlockProcess { get; set; } = true;
            public bool ThrowOnSetAlignment { get; set; }
            public bool ResetCalled { get; private set; }
            public bool SetAlignmentCalled { get; private set; }
            public int DisposeCallCount { get; private set; }
            public byte FirstImageByte { get; private set; }

            public IReadOnlyList<long> ProcessedFrameIds
            {
                get
                {
                    lock (_gate)
                    {
                        return _processedFrameIds.ToArray();
                    }
                }
            }

            public LocalizationFrameResult Process(LocalizationFrame frame, long generation)
            {
                _started.TrySetResult(true);
                if (BlockProcess)
                    _releaseGate.Wait(TimeSpan.FromSeconds(3));

                lock (_gate)
                {
                    FirstImageByte = frame.GrayscaleImage[0];
                    _processedFrameIds.Add(frame.FrameId);
                    _processedCounts.TryGetValue(frame.FrameId, out int count);
                    _processedCounts[frame.FrameId] = count + 1;
                }

                return LocalizationFrameResult.Succeeded(
                    frame,
                    generation,
                    frame.CaptureTimestampNs,
                    frame.CaptureTimestampNs + 1,
                    Matrix4x4.identity,
                    LocalizationQuality.RECOGNIZED,
                    0.8f,
                    10,
                    default);
            }

            public void Reset()
            {
                ResetCalled = true;
            }

            public void SetAlignmentTransform(Matrix4x4 unityWorldFromScanAlignment)
            {
                SetAlignmentCalled = true;
                if (ThrowOnSetAlignment)
                    throw new InvalidOperationException("Expected alignment failure.");
            }

            public void Dispose()
            {
                DisposeCallCount++;
                _releaseGate.Dispose();
            }

            public void Release()
            {
                _releaseGate.Set();
            }

            public Task WaitUntilStartedAsync()
            {
                return _started.Task;
            }

            public async Task WaitUntilProcessedAsync(long frameId, int expectedCount = 1)
            {
                DateTime deadline = DateTime.UtcNow.AddSeconds(3);
                while (DateTime.UtcNow < deadline)
                {
                    lock (_gate)
                    {
                        if (_processedCounts.TryGetValue(frameId, out int count) && count >= expectedCount)
                            return;
                    }

                    await Task.Delay(5);
                }

                Assert.Fail($"Frame {frameId} was not processed {expectedCount} time(s).");
            }
        }

        private sealed class ThrowingProcessor : ILocalizationProcessor
        {
            public TaskCompletionSource<bool> ProcessAttempted { get; } = new TaskCompletionSource<bool>();

            public LocalizationFrameResult Process(LocalizationFrame frame, long generation)
            {
                ProcessAttempted.TrySetResult(true);
                throw new InvalidOperationException("Expected fake processor failure.");
            }

            public void Reset()
            {
            }

            public void SetAlignmentTransform(Matrix4x4 unityWorldFromScanAlignment)
            {
            }

            public void Dispose()
            {
            }
        }
    }
}
