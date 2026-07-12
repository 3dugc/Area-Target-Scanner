using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for XRSpace behavior.
    /// Feature: pointcloud-localization, Properties 8, 9, 10
    /// </summary>
    [TestFixture]
    public class XRSpacePropertyTests
    {
        private List<GameObject> _gameObjects = new List<GameObject>();

        private XRSpace CreateXRSpace()
        {
            var go = new GameObject("TestXRSpace");
            _gameObjects.Add(go);
            return go.AddComponent<XRSpace>();
        }

        [TearDown]
        public void TearDown()
        {
            foreach (var go in _gameObjects)
                if (go != null) Object.DestroyImmediate(go);
            _gameObjects.Clear();
        }

        /// <summary>
        /// Recording IDataProcessor that tracks ProcessData and ResetProcessor calls.
        /// </summary>
        private class RecordingProcessor : IDataProcessor<SceneUpdateData>
        {
            public int ProcessDataCallCount { get; private set; }
            public int ResetCallCount { get; private set; }
            public DataProcessorTrigger LastTrigger { get; private set; }

            public Task<SceneUpdateData> ProcessData(SceneUpdateData data, DataProcessorTrigger trigger)
            {
                ProcessDataCallCount++;
                LastTrigger = trigger;
                return Task.FromResult(data);
            }

            public Task ResetProcessor()
            {
                ResetCallCount++;
                return Task.CompletedTask;
            }
        }

        #region Property 8: XRSpace Ignore 跳过更新

        /// <summary>
        /// Property 8: For any SceneUpdateData with Ignore=true,
        /// XRSpace.SceneUpdate() should not change the Transform position/rotation.
        /// **Validates: Requirements 7.4**
        /// </summary>
        [Test]
        public void Ignore_True_Does_Not_Change_Transform([Values(0f, 1f, -5f)] float x,
                                                           [Values(0f, 2f, -3f)] float y,
                                                           [Values(0f, 3f, 7f)] float z)
        {
            var xrSpace = CreateXRSpace();
            var initialPos = new Vector3(x, y, z);
            var initialRot = Quaternion.Euler(10f, 20f, 30f);
            xrSpace.transform.SetPositionAndRotation(initialPos, initialRot);

            var data = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(new Vector3(99f, 99f, 99f), Quaternion.Euler(45f, 45f, 45f), Vector3.one),
                Ignore = true
            };

            xrSpace.SceneUpdate(data).Wait();

            Assert.AreEqual(initialPos, xrSpace.transform.position,
                "Position should not change when Ignore=true");
            Assert.AreEqual(initialRot, xrSpace.transform.rotation,
                "Rotation should not change when Ignore=true");
        }

        /// <summary>
        /// Property 8 (FsCheck): For any random pose, Ignore=true preserves transform.
        /// **Validates: Requirements 7.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property Ignore_True_Preserves_Transform_For_Any_Pose(float px, float py, float pz)
        {
            // Skip NaN/Infinity which are not meaningful poses
            if (float.IsNaN(px) || float.IsInfinity(px) ||
                float.IsNaN(py) || float.IsInfinity(py) ||
                float.IsNaN(pz) || float.IsInfinity(pz))
                return true.ToProperty();

            var xrSpace = CreateXRSpace();
            var initialPos = Vector3.zero;
            var initialRot = Quaternion.identity;
            xrSpace.transform.SetPositionAndRotation(initialPos, initialRot);

            var data = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(new Vector3(px, py, pz), Quaternion.identity, Vector3.one),
                Ignore = true
            };

            xrSpace.SceneUpdate(data).Wait();

            return (xrSpace.transform.position == initialPos &&
                    xrSpace.transform.rotation == initialRot)
                .ToProperty()
                .Label("Ignore=true should preserve transform regardless of pose data");
        }

        #endregion

        #region Property 9: XRSpace 处理器链行为

        /// <summary>
        /// Property 9a: When ProcessPoses=true and N processors registered,
        /// all N processors' ProcessData should be called.
        /// **Validates: Requirements 7.5, 7.6, 8.5**
        /// </summary>
        [TestCase(1)]
        [TestCase(2)]
        [TestCase(3)]
        [TestCase(5)]
        public void ProcessPoses_True_Calls_All_Processors(int processorCount)
        {
            var xrSpace = CreateXRSpace();
            xrSpace.ProcessPoses = true;

            var processors = new List<RecordingProcessor>();
            for (int i = 0; i < processorCount; i++)
            {
                var proc = new RecordingProcessor();
                processors.Add(proc);
                xrSpace.AddProcessor(proc);
            }

            var data = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(Vector3.one, Quaternion.identity, Vector3.one),
                Ignore = false
            };

            xrSpace.SceneUpdate(data).Wait();

            for (int i = 0; i < processorCount; i++)
            {
                Assert.AreEqual(1, processors[i].ProcessDataCallCount,
                    $"Processor {i} should be called exactly once");
                Assert.AreEqual(DataProcessorTrigger.NewData, processors[i].LastTrigger,
                    $"Processor {i} should receive NewData trigger");
            }
        }

        /// <summary>
        /// Property 9b: When ProcessPoses=false, no processors should be called
        /// and pose should be applied directly.
        /// **Validates: Requirements 7.6**
        /// </summary>
        [TestCase(1)]
        [TestCase(3)]
        public void ProcessPoses_False_Skips_Processors(int processorCount)
        {
            var xrSpace = CreateXRSpace();
            xrSpace.ProcessPoses = false;

            var processors = new List<RecordingProcessor>();
            for (int i = 0; i < processorCount; i++)
            {
                var proc = new RecordingProcessor();
                processors.Add(proc);
                xrSpace.AddProcessor(proc);
            }

            var targetPos = new Vector3(5f, 10f, 15f);
            var data = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(targetPos, Quaternion.identity, Vector3.one),
                Ignore = false
            };

            xrSpace.SceneUpdate(data).Wait();

            foreach (var proc in processors)
            {
                Assert.AreEqual(0, proc.ProcessDataCallCount,
                    "Processors should not be called when ProcessPoses=false");
            }

            Assert.AreEqual(targetPos.x, xrSpace.transform.position.x, 0.001f,
                "Pose should be applied directly when ProcessPoses=false");
            Assert.AreEqual(targetPos.y, xrSpace.transform.position.y, 0.001f);
            Assert.AreEqual(targetPos.z, xrSpace.transform.position.z, 0.001f);
        }

        /// <summary>
        /// Property 9c: When ProcessPoses=true but no processors registered,
        /// pose should be applied directly.
        /// **Validates: Requirements 8.5**
        /// </summary>
        [Test]
        public void ProcessPoses_True_No_Processors_Applies_Directly()
        {
            var xrSpace = CreateXRSpace();
            xrSpace.ProcessPoses = true;

            var targetPos = new Vector3(7f, 8f, 9f);
            var data = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(targetPos, Quaternion.identity, Vector3.one),
                Ignore = false
            };

            xrSpace.SceneUpdate(data).Wait();

            Assert.AreEqual(targetPos.x, xrSpace.transform.position.x, 0.001f,
                "Pose should be applied directly when no processors registered");
            Assert.AreEqual(targetPos.y, xrSpace.transform.position.y, 0.001f);
            Assert.AreEqual(targetPos.z, xrSpace.transform.position.z, 0.001f);
        }

        #endregion

        #region Property 10: ResetScene 重置所有处理器

        /// <summary>
        /// Property 10: For any XRSpace with N registered IDataProcessors,
        /// calling ResetScene() should call each processor's ResetProcessor() exactly once.
        /// **Validates: Requirements 7.8, 11.3**
        /// </summary>
        [TestCase(1)]
        [TestCase(2)]
        [TestCase(3)]
        [TestCase(5)]
        public void ResetScene_Calls_Each_Processor_ResetProcessor_Once(int processorCount)
        {
            var xrSpace = CreateXRSpace();

            var processors = new List<RecordingProcessor>();
            for (int i = 0; i < processorCount; i++)
            {
                var proc = new RecordingProcessor();
                processors.Add(proc);
                xrSpace.AddProcessor(proc);
            }

            xrSpace.ResetScene().Wait();

            for (int i = 0; i < processorCount; i++)
            {
                Assert.AreEqual(1, processors[i].ResetCallCount,
                    $"Processor {i} ResetProcessor should be called exactly once");
            }
        }

        /// <summary>
        /// Property 10b: ResetScene with zero processors should not throw.
        /// **Validates: Requirements 7.8**
        /// </summary>
        [Test]
        public void ResetScene_No_Processors_Does_Not_Throw()
        {
            var xrSpace = CreateXRSpace();
            Assert.DoesNotThrow(() => xrSpace.ResetScene().Wait(),
                "ResetScene with no processors should not throw");
        }

        /// <summary>
        /// Property 10c: Multiple ResetScene calls accumulate reset counts.
        /// **Validates: Requirements 7.8, 11.3**
        /// </summary>
        [Test]
        public void ResetScene_Called_Twice_Resets_Each_Processor_Twice()
        {
            var xrSpace = CreateXRSpace();
            var proc = new RecordingProcessor();
            xrSpace.AddProcessor(proc);

            xrSpace.ResetScene().Wait();
            xrSpace.ResetScene().Wait();

            Assert.AreEqual(2, proc.ResetCallCount,
                "Each ResetScene call should invoke ResetProcessor once per processor");
        }

        #endregion
    }
}
