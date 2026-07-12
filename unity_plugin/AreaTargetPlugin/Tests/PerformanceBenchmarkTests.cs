using System;
using System.Diagnostics;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Performance benchmark tests for the tracking pipeline.
    /// Validates: frame processing latency, memory stability, throughput.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class PerformanceBenchmarkTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region Frame Processing Latency

        [Test]
        public void ProcessFrame_EmptyDB_Under5ms()
        {
            var tracker = new AreaTargetTracker();
            var intrinsics = new Matrix4x4();
            intrinsics.m00 = 500; intrinsics.m11 = 500; intrinsics.m02 = 320; intrinsics.m12 = 240;
            var frame = new CameraFrame
            {
                ImageData = new byte[640 * 480],
                Width = 640,
                Height = 480,
                Intrinsics = intrinsics
            };

            // Warmup
            tracker.ProcessFrame(frame);

            var sw = Stopwatch.StartNew();
            int iterations = 100;
            for (int i = 0; i < iterations; i++)
            {
                tracker.ProcessFrame(frame);
            }
            sw.Stop();

            double avgMs = sw.Elapsed.TotalMilliseconds / iterations;
            UnityEngine.Debug.Log($"[Benchmark] ProcessFrame avg: {avgMs:F2}ms ({iterations} iterations)");
            Assert.Less(avgMs, 5.0, $"ProcessFrame too slow: {avgMs:F2}ms avg");

            tracker.Dispose();
        }

        [Test]
        public void KalmanFilter_Update_Under1ms()
        {
            var filter = new KalmanPoseFilter();
            var pose = Matrix4x4.TRS(Vector3.one, Quaternion.Euler(10, 20, 30), Vector3.one);

            // Warmup
            filter.Update(pose);

            var sw = Stopwatch.StartNew();
            int iterations = 1000;
            for (int i = 0; i < iterations; i++)
            {
                filter.Update(pose);
            }
            sw.Stop();

            double avgMs = sw.Elapsed.TotalMilliseconds / iterations;
            UnityEngine.Debug.Log($"[Benchmark] KalmanFilter.Update avg: {avgMs:F4}ms ({iterations} iterations)");
            Assert.Less(avgMs, 1.0, $"KalmanFilter too slow: {avgMs:F4}ms avg");
        }

        #endregion

        #region Throughput

        [Test]
        public void Tracker_Throughput_AtLeast30FPS()
        {
            var tracker = new AreaTargetTracker();
            var intrinsics2 = new Matrix4x4();
            intrinsics2.m00 = 500; intrinsics2.m11 = 500; intrinsics2.m02 = 320; intrinsics2.m12 = 240;
            var frame = new CameraFrame
            {
                ImageData = new byte[640 * 480],
                Width = 640,
                Height = 480,
                Intrinsics = intrinsics2
            };

            var sw = Stopwatch.StartNew();
            int frames = 0;
            while (sw.Elapsed.TotalSeconds < 1.0)
            {
                tracker.ProcessFrame(frame);
                frames++;
            }
            sw.Stop();

            double fps = frames / sw.Elapsed.TotalSeconds;
            UnityEngine.Debug.Log($"[Benchmark] Throughput: {fps:F1} FPS");
            Assert.GreaterOrEqual(fps, 30.0, $"Throughput too low: {fps:F1} FPS");

            tracker.Dispose();
        }

        #endregion

        #region Memory Stability

        [Test]
        public void ProcessFrame_1000Iterations_MemoryStable()
        {
            var tracker = new AreaTargetTracker();
            var intrinsics3 = new Matrix4x4();
            intrinsics3.m00 = 500; intrinsics3.m11 = 500; intrinsics3.m02 = 320; intrinsics3.m12 = 240;
            var frame = new CameraFrame
            {
                ImageData = new byte[640 * 480],
                Width = 640,
                Height = 480,
                Intrinsics = intrinsics3
            };

            // Warmup + baseline
            for (int i = 0; i < 10; i++)
                tracker.ProcessFrame(frame);

            GC.Collect();
            GC.WaitForPendingFinalizers();
            long memBefore = GC.GetTotalMemory(true);

            for (int i = 0; i < 1000; i++)
            {
                tracker.ProcessFrame(frame);
            }

            GC.Collect();
            GC.WaitForPendingFinalizers();
            long memAfter = GC.GetTotalMemory(true);

            long deltaKB = (memAfter - memBefore) / 1024;
            UnityEngine.Debug.Log($"[Benchmark] Memory delta after 1000 frames: {deltaKB}KB");
            // Allow up to 10MB growth (generous for GC variance)
            Assert.Less(deltaKB, 10240, $"Possible memory leak: {deltaKB}KB growth");

            tracker.Dispose();
        }

        #endregion

        #region Dispose Safety

        [Test]
        public void Dispose_MultipleCalls_NoException()
        {
            var tracker = new AreaTargetTracker();
            Assert.DoesNotThrow(() => tracker.Dispose());
            Assert.DoesNotThrow(() => tracker.Dispose());
            Assert.DoesNotThrow(() => tracker.Dispose());
        }

        [Test]
        public void ProcessFrame_AfterDispose_ReturnsLost()
        {
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            var frame = new CameraFrame
            {
                ImageData = new byte[100],
                Width = 10,
                Height = 10,
                Intrinsics = Matrix4x4.identity
            };

            TrackingResult result = tracker.ProcessFrame(frame);
            Assert.AreEqual(TrackingState.LOST, result.State);
        }

        [Test]
        public void Reset_AfterDispose_NoException()
        {
            var tracker = new AreaTargetTracker();
            tracker.Dispose();
            Assert.DoesNotThrow(() => tracker.Reset());
        }

        #endregion
    }
}
