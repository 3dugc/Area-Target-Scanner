using System;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    [IgnoreLogErrors]
    public class LocalizerIntegrationTests
    {
        #region Stub Classes

        private class StubCameraData : ICameraData
        {
            public byte[] GetBytes() => new byte[] { 128, 64, 32 };
            public int Width => 640;
            public int Height => 480;
            public int Channels => 1;
            public Vector4 Intrinsics => new Vector4(500f, 500f, 320f, 240f);
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
        }

        private class StubPlatformSupport : IPlatformSupport
        {
            public IPlatformUpdateResult Result { get; set; }

            public Task<IPlatformUpdateResult> UpdatePlatform()
            {
                return Task.FromResult(Result);
            }

            public Task ConfigurePlatform() => Task.CompletedTask;
            public Task StopAndCleanUp() => Task.CompletedTask;
        }

        private class StubLocalizer : ILocalizer
        {
            public event Action<int[]> OnSuccessfulLocalizations;
            public ILocalizationResult ResultToReturn { get; set; }
            public bool LocalizeCalled { get; private set; }
            public ICameraData LastCameraData { get; private set; }

            public Task<ILocalizationResult> Localize(ICameraData cameraData)
            {
                LocalizeCalled = true;
                LastCameraData = cameraData;

                if (cameraData == null)
                {
                    return Task.FromResult<ILocalizationResult>(LocalizationResult.Failed());
                }

                return Task.FromResult(ResultToReturn);
            }

            public Task StopAndCleanUp() => Task.CompletedTask;
        }

        private class StubSceneUpdater : ISceneUpdater
        {
            public bool UpdateSceneCalled { get; private set; }
            public MapEntry LastEntry { get; private set; }
            public ICameraData LastCameraData { get; private set; }
            public ILocalizationResult LastResult { get; private set; }

            public Task UpdateScene(MapEntry entry, ICameraData cameraData, ILocalizationResult result)
            {
                UpdateSceneCalled = true;
                LastEntry = entry;
                LastCameraData = cameraData;
                LastResult = result;
                return Task.CompletedTask;
            }
        }

        private class StubSceneUpdateable : ISceneUpdateable
        {
            public Transform GetTransform() => null;
            public Task SceneUpdate(SceneUpdateData data) => Task.CompletedTask;
            public Task ResetScene() => Task.CompletedTask;
        }

        #endregion

        private StubPlatformSupport _platform;
        private StubLocalizer _localizer;
        private StubSceneUpdater _sceneUpdater;
        private LocalizationPipeline _pipeline;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            MapManager.Clear();
            _platform = new StubPlatformSupport();
            _localizer = new StubLocalizer();
            _sceneUpdater = new StubSceneUpdater();
            _pipeline = new LocalizationPipeline(_platform, _localizer, _sceneUpdater);
        }

        [TearDown]
        public void TearDown()
        {
            MapManager.Clear();
        }

        /// <summary>
        /// Validates Requirement 9.1: Full pipeline success path.
        /// Platform returns success with quality=80, localizer returns success with mapId=1,
        /// MapEntry registered for mapId=1 → SceneUpdater.UpdateScene is called.
        /// </summary>
        [Test]
        public async Task RunFrame_FullPipelineSuccess_UpdateSceneCalled()
        {
            // Arrange
            var cameraData = new StubCameraData();
            _platform.Result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 80,
                CameraData = cameraData
            };

            var locResult = new LocalizationResult
            {
                Success = true,
                MapId = 1,
                Pose = Matrix4x4.TRS(new Vector3(1, 2, 3), Quaternion.identity, Vector3.one)
            };
            _localizer.ResultToReturn = locResult;

            var entry = new MapEntry { MapId = 1, SceneParent = new StubSceneUpdateable() };
            MapManager.RegisterMap(1, entry);

            // Act
            var result = await _pipeline.RunFrame();

            // Assert
            Assert.IsTrue(result.Success);
            Assert.AreEqual(1, result.MapId);
            Assert.IsTrue(_localizer.LocalizeCalled);
            Assert.IsTrue(_sceneUpdater.UpdateSceneCalled);
            Assert.AreEqual(entry, _sceneUpdater.LastEntry);
            Assert.AreEqual(cameraData, _sceneUpdater.LastCameraData);
            Assert.AreEqual(locResult, _sceneUpdater.LastResult);
        }

        /// <summary>
        /// Validates Requirement 9.1: Platform failure skips localization entirely.
        /// </summary>
        [Test]
        public async Task RunFrame_PlatformFailure_SkipsLocalization()
        {
            // Arrange
            _platform.Result = new PlatformUpdateResult
            {
                Success = false,
                TrackingQuality = 0,
                CameraData = null
            };

            // Act
            var result = await _pipeline.RunFrame();

            // Assert
            Assert.IsFalse(result.Success);
            Assert.IsFalse(_localizer.LocalizeCalled);
            Assert.IsFalse(_sceneUpdater.UpdateSceneCalled);
        }

        /// <summary>
        /// Validates Requirement 13.7: Low tracking quality (below default threshold 50) skips localization.
        /// </summary>
        [Test]
        public async Task RunFrame_LowTrackingQuality_SkipsLocalization()
        {
            // Arrange
            _platform.Result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 20,
                CameraData = new StubCameraData()
            };

            // Act
            var result = await _pipeline.RunFrame();

            // Assert
            Assert.IsFalse(result.Success);
            Assert.IsFalse(_localizer.LocalizeCalled);
            Assert.IsFalse(_sceneUpdater.UpdateSceneCalled);
        }

        /// <summary>
        /// Validates Requirement 9.1: Localization failure skips scene update.
        /// </summary>
        [Test]
        public async Task RunFrame_LocalizationFailure_SkipsSceneUpdate()
        {
            // Arrange
            _platform.Result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 80,
                CameraData = new StubCameraData()
            };
            _localizer.ResultToReturn = LocalizationResult.Failed();

            // Act
            var result = await _pipeline.RunFrame();

            // Assert
            Assert.IsFalse(result.Success);
            Assert.IsTrue(_localizer.LocalizeCalled);
            Assert.IsFalse(_sceneUpdater.UpdateSceneCalled);
        }

        /// <summary>
        /// Validates Requirement 9.3: Localization succeeds but MapManager has no entry for the mapId.
        /// Should log warning and skip scene update.
        /// </summary>
        [Test]
        public async Task RunFrame_MissingMapEntry_SkipsSceneUpdate()
        {
            // Arrange
            _platform.Result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 80,
                CameraData = new StubCameraData()
            };
            _localizer.ResultToReturn = new LocalizationResult
            {
                Success = true,
                MapId = 999,
                Pose = Matrix4x4.identity
            };
            // Do NOT register mapId=999 in MapManager

            // Act
            var result = await _pipeline.RunFrame();

            // Assert — localization succeeded but scene update was skipped
            Assert.IsTrue(result.Success);
            Assert.AreEqual(999, result.MapId);
            Assert.IsTrue(_localizer.LocalizeCalled);
            Assert.IsFalse(_sceneUpdater.UpdateSceneCalled);
        }

        /// <summary>
        /// Validates Requirement 2.6: Null ICameraData from platform.
        /// The localizer receives null and returns Failed().
        /// </summary>
        [Test]
        public async Task RunFrame_NullCameraData_LocalizerReturnsFailed()
        {
            // Arrange
            _platform.Result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 80,
                CameraData = null
            };

            // Act
            var result = await _pipeline.RunFrame();

            // Assert
            Assert.IsFalse(result.Success);
            Assert.IsTrue(_localizer.LocalizeCalled);
            Assert.IsNull(_localizer.LastCameraData);
            Assert.IsFalse(_sceneUpdater.UpdateSceneCalled);
        }
    }
}
