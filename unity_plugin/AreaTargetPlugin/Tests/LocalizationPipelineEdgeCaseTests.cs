using System;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Edge case tests for LocalizationPipeline covering:
    /// - Platform exception handling
    /// - Localizer exception handling
    /// - SceneUpdater exception handling (non-fatal)
    /// - TrackingQualityThreshold setter behavior
    /// - StopAndCleanUp error recovery
    /// - Constructor null argument validation
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class LocalizationPipelineEdgeCaseTests
    {
        #region Stubs

        private class ThrowingPlatform : IPlatformSupport
        {
            public Task<IPlatformUpdateResult> UpdatePlatform()
            {
                throw new InvalidOperationException("Camera hardware failure");
            }
            public Task ConfigurePlatform() => Task.CompletedTask;
            public Task StopAndCleanUp() => throw new InvalidOperationException("Cleanup failed");
        }

        private class ThrowingLocalizer : ILocalizer
        {
            public event Action<int[]> OnSuccessfulLocalizations;
            public Task<ILocalizationResult> Localize(ICameraData cameraData)
            {
                throw new InvalidOperationException("Localization crash");
            }
            public Task StopAndCleanUp() => throw new InvalidOperationException("Localizer cleanup failed");
        }

        private class ThrowingSceneUpdater : ISceneUpdater
        {
            public Task UpdateScene(MapEntry entry, ICameraData cameraData, ILocalizationResult result)
            {
                throw new InvalidOperationException("Scene update crash");
            }
        }

        private class StubCameraData : ICameraData
        {
            public byte[] GetBytes() => new byte[] { 128 };
            public int Width => 640;
            public int Height => 480;
            public int Channels => 1;
            public Vector4 Intrinsics => new Vector4(500f, 500f, 320f, 240f);
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
        }

        private class ConfigurablePlatform : IPlatformSupport
        {
            public IPlatformUpdateResult Result { get; set; }
            public bool StopCalled { get; private set; }

            public Task<IPlatformUpdateResult> UpdatePlatform()
                => Task.FromResult(Result);
            public Task ConfigurePlatform() => Task.CompletedTask;
            public Task StopAndCleanUp() { StopCalled = true; return Task.CompletedTask; }
        }

        private class ConfigurableLocalizer : ILocalizer
        {
            public event Action<int[]> OnSuccessfulLocalizations;
            public ILocalizationResult ResultToReturn { get; set; }
            public bool StopCalled { get; private set; }

            public Task<ILocalizationResult> Localize(ICameraData cameraData)
                => Task.FromResult(ResultToReturn);
            public Task StopAndCleanUp() { StopCalled = true; return Task.CompletedTask; }
        }

        private class StubSceneUpdater : ISceneUpdater
        {
            public bool Called { get; private set; }
            public Task UpdateScene(MapEntry entry, ICameraData cameraData, ILocalizationResult result)
            {
                Called = true;
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

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        [TearDown]
        public void TearDown()
        {
            MapManager.Clear();
        }

        #region Constructor Validation

        [Test]
        public void Constructor_NullPlatform_ThrowsArgumentNull()
        {
            Assert.Throws<ArgumentNullException>(() =>
                new LocalizationPipeline(null, new ConfigurableLocalizer(), new StubSceneUpdater()));
        }

        [Test]
        public void Constructor_NullLocalizer_ThrowsArgumentNull()
        {
            Assert.Throws<ArgumentNullException>(() =>
                new LocalizationPipeline(new ConfigurablePlatform(), null, new StubSceneUpdater()));
        }

        [Test]
        public void Constructor_NullSceneUpdater_ThrowsArgumentNull()
        {
            Assert.Throws<ArgumentNullException>(() =>
                new LocalizationPipeline(new ConfigurablePlatform(), new ConfigurableLocalizer(), null));
        }

        #endregion

        #region Platform Exception Handling

        [Test]
        public async Task RunFrame_PlatformThrows_ReturnsFailed()
        {
            LogAssert.ignoreFailingMessages = true;
            var pipeline = new LocalizationPipeline(
                new ThrowingPlatform(),
                new ConfigurableLocalizer(),
                new StubSceneUpdater());

            var result = await pipeline.RunFrame();

            Assert.IsFalse(result.Success);
        }

        #endregion

        #region Localizer Exception Handling

        [Test]
        public async Task RunFrame_LocalizerThrows_ReturnsFailed()
        {
            LogAssert.ignoreFailingMessages = true;
            var platform = new ConfigurablePlatform
            {
                Result = new PlatformUpdateResult
                {
                    Success = true,
                    TrackingQuality = 80,
                    CameraData = new StubCameraData()
                }
            };
            var pipeline = new LocalizationPipeline(
                platform,
                new ThrowingLocalizer(),
                new StubSceneUpdater());

            var result = await pipeline.RunFrame();

            Assert.IsFalse(result.Success);
        }

        #endregion

        #region SceneUpdater Exception Handling

        [Test]
        public async Task RunFrame_SceneUpdaterThrows_StillReturnsLocalizationResult()
        {
            LogAssert.ignoreFailingMessages = true;
            var platform = new ConfigurablePlatform
            {
                Result = new PlatformUpdateResult
                {
                    Success = true,
                    TrackingQuality = 80,
                    CameraData = new StubCameraData()
                }
            };
            var localizer = new ConfigurableLocalizer
            {
                ResultToReturn = new LocalizationResult
                {
                    Success = true,
                    MapId = 1,
                    Pose = Matrix4x4.identity
                }
            };
            MapManager.RegisterMap(1, new MapEntry { MapId = 1, SceneParent = new StubSceneUpdateable() });

            var pipeline = new LocalizationPipeline(platform, localizer, new ThrowingSceneUpdater());

            // SceneUpdater throws, but the pipeline should still return the localization result
            var result = await pipeline.RunFrame();

            Assert.IsTrue(result.Success);
            Assert.AreEqual(1, result.MapId);
        }

        #endregion

        #region TrackingQualityThreshold

        [Test]
        public async Task TrackingQualityThreshold_SetTo0_AcceptsAllFrames()
        {
            var platform = new ConfigurablePlatform
            {
                Result = new PlatformUpdateResult
                {
                    Success = true,
                    TrackingQuality = 1,
                    CameraData = new StubCameraData()
                }
            };
            var localizer = new ConfigurableLocalizer
            {
                ResultToReturn = new LocalizationResult { Success = true, MapId = 1, Pose = Matrix4x4.identity }
            };
            var sceneUpdater = new StubSceneUpdater();
            MapManager.RegisterMap(1, new MapEntry { MapId = 1, SceneParent = new StubSceneUpdateable() });

            var pipeline = new LocalizationPipeline(platform, localizer, sceneUpdater);
            pipeline.TrackingQualityThreshold = 0;

            var result = await pipeline.RunFrame();

            Assert.IsTrue(result.Success);
        }

        [Test]
        public async Task TrackingQualityThreshold_SetTo100_RejectsQuality99()
        {
            var platform = new ConfigurablePlatform
            {
                Result = new PlatformUpdateResult
                {
                    Success = true,
                    TrackingQuality = 99,
                    CameraData = new StubCameraData()
                }
            };
            var pipeline = new LocalizationPipeline(
                platform, new ConfigurableLocalizer(), new StubSceneUpdater());
            pipeline.TrackingQualityThreshold = 100;

            var result = await pipeline.RunFrame();

            Assert.IsFalse(result.Success);
        }

        [Test]
        public void TrackingQualityThreshold_DefaultIs50()
        {
            var pipeline = new LocalizationPipeline(
                new ConfigurablePlatform(), new ConfigurableLocalizer(), new StubSceneUpdater());

            Assert.AreEqual(50, pipeline.TrackingQualityThreshold);
        }

        #endregion

        #region StopAndCleanUp Error Recovery

        [Test]
        public async Task StopAndCleanUp_BothThrow_DoesNotPropagate()
        {
            LogAssert.ignoreFailingMessages = true;
            var pipeline = new LocalizationPipeline(
                new ThrowingPlatform(),
                new ThrowingLocalizer(),
                new StubSceneUpdater());

            // Should not throw even though both platform and localizer cleanup throw
            Assert.DoesNotThrowAsync(async () => await pipeline.StopAndCleanUp());
        }

        [Test]
        public async Task StopAndCleanUp_CallsBothComponents()
        {
            var platform = new ConfigurablePlatform();
            var localizer = new ConfigurableLocalizer();
            var pipeline = new LocalizationPipeline(platform, localizer, new StubSceneUpdater());

            await pipeline.StopAndCleanUp();

            Assert.IsTrue(platform.StopCalled);
            Assert.IsTrue(localizer.StopCalled);
        }

        #endregion
    }
}
