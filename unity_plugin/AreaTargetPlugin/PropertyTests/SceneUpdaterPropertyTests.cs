using System.Threading.Tasks;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for SceneUpdater Ignore flag behavior.
    /// Feature: pointcloud-localization, Property 7: SceneUpdater 的 Ignore 标志与定位结果一致
    /// **Validates: Requirements 6.2, 6.3**
    /// </summary>
    [TestFixture]
    public class SceneUpdaterPropertyTests
    {
        /// <summary>
        /// Recording ISceneUpdateable that captures the SceneUpdateData passed to SceneUpdate.
        /// </summary>
        private class RecordingSceneUpdateable : ISceneUpdateable
        {
            public SceneUpdateData LastData { get; private set; }
            public Transform GetTransform() => null;
            public Task SceneUpdate(SceneUpdateData data)
            {
                LastData = data;
                return Task.CompletedTask;
            }
            public Task ResetScene() => Task.CompletedTask;
        }

        private class StubLocalizationResult : ILocalizationResult
        {
            public bool Success { get; set; }
            public int MapId { get; set; }
            public Matrix4x4 Pose { get; set; }
        }

        private class StubCameraData : ICameraData
        {
            public byte[] GetBytes() => new byte[0];
            public int Width => 640;
            public int Height => 480;
            public int Channels => 1;
            public Vector4 Intrinsics => Vector4.zero;
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
        }

        /// <summary>
        /// Property 7a: When ILocalizationResult.Success is true,
        /// SceneUpdater constructs SceneUpdateData with Ignore=false.
        /// **Validates: Requirements 6.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property SuccessResult_IgnoreIsFalse(int mapId)
        {
            var recorder = new RecordingSceneUpdateable();
            var entry = new MapEntry { MapId = mapId, SceneParent = recorder };
            var result = new StubLocalizationResult { Success = true, MapId = mapId, Pose = Matrix4x4.identity };
            var updater = new SceneUpdater();

            updater.UpdateScene(entry, new StubCameraData(), result).Wait();

            return (recorder.LastData != null && !recorder.LastData.Ignore).ToProperty()
                .Label("Success=true should produce Ignore=false");
        }

        /// <summary>
        /// Property 7b: When ILocalizationResult.Success is false,
        /// SceneUpdater constructs SceneUpdateData with Ignore=true.
        /// **Validates: Requirements 6.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FailedResult_IgnoreIsTrue(int mapId)
        {
            var recorder = new RecordingSceneUpdateable();
            var entry = new MapEntry { MapId = mapId, SceneParent = recorder };
            var result = new StubLocalizationResult { Success = false, MapId = mapId, Pose = Matrix4x4.identity };
            var updater = new SceneUpdater();

            updater.UpdateScene(entry, new StubCameraData(), result).Wait();

            return (recorder.LastData != null && recorder.LastData.Ignore).ToProperty()
                .Label("Success=false should produce Ignore=true");
        }
    }
}
