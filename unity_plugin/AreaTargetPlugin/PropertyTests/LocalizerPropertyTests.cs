using System;
using System.Threading.Tasks;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for PointCloudLocalizer and LocalizationResult.
    /// Feature: pointcloud-localization
    /// Properties 1, 2, 3, 15
    /// </summary>
    [TestFixture]
    public class LocalizerPropertyTests
    {
        /// <summary>
        /// Stub ICameraData implementation for property testing.
        /// </summary>
        private class StubCameraData : ICameraData
        {
            public StubCameraData(int width, int height)
            {
                Width = width;
                Height = height;
            }

            public byte[] GetBytes() => new byte[Math.Max(0, Width * Height)];
            public int Width { get; }
            public int Height { get; }
            public int Channels => 1;
            public Vector4 Intrinsics => new Vector4(500f, 500f, 320f, 240f);
            public Vector3 CameraPositionOnCapture => Vector3.zero;
            public Quaternion CameraRotationOnCapture => Quaternion.identity;
        }

        // =====================================================================
        // Property 1: 无效图像尺寸导致定位失败
        // For any ICameraData where Width <= 0 or Height <= 0,
        // Localizer.Localize() should return Success=false.
        // **Validates: Requirements 1.5**
        // =====================================================================

        /// <summary>
        /// Property 1a: When Width is non-positive, Localize returns Success=false.
        /// The dimension check occurs before ProcessFrame, so null engine is safe.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidWidth_LocalizeFails(NegativeInt width, PositiveInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success).ToProperty()
                .Label($"Width={width.Get}, Height={height.Get}: Localize should fail for non-positive Width");
        }

        /// <summary>
        /// Property 1b: When Height is non-positive, Localize returns Success=false.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidHeight_LocalizeFails(PositiveInt width, NegativeInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success).ToProperty()
                .Label($"Width={width.Get}, Height={height.Get}: Localize should fail for non-positive Height");
        }

        /// <summary>
        /// Property 1c: When both Width and Height are non-positive, Localize returns Success=false.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property BothDimensionsInvalid_LocalizeFails(NegativeInt width, NegativeInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success).ToProperty()
                .Label($"Width={width.Get}, Height={height.Get}: Localize should fail when both dimensions invalid");
        }

        /// <summary>
        /// Property 1d: Zero dimensions also cause failure.
        /// </summary>
        [Test]
        public void ZeroDimensions_LocalizeFails()
        {
            var localizer = new PointCloudLocalizer(1, null, null);

            var zeroWidth = new StubCameraData(0, 100);
            var zeroHeight = new StubCameraData(100, 0);
            var bothZero = new StubCameraData(0, 0);

            Assert.IsFalse(localizer.Localize(zeroWidth).Result.Success, "Width=0 should fail");
            Assert.IsFalse(localizer.Localize(zeroHeight).Result.Success, "Height=0 should fail");
            Assert.IsFalse(localizer.Localize(bothZero).Result.Success, "Both=0 should fail");
        }

        // =====================================================================
        // Property 2: 定位成功触发事件且携带正确 mapId
        // For any successful localization (Success==true),
        // OnSuccessfulLocalizations event should be triggered with the correct mapId.
        // **Validates: Requirements 2.5**
        //
        // Note: VisualLocalizationEngine is a concrete class with OpenCV dependency,
        // so we cannot mock it in unit tests. We test the event mechanism by:
        // (a) Verifying LocalizationResult carries the correct mapId
        // (b) Verifying the event subscription/firing mechanism via null-engine
        //     exception path (which returns Failed, confirming no false-positive events)
        // (c) Verifying that failed localizations do NOT fire the event
        // =====================================================================

        /// <summary>
        /// Property 2a: A successful LocalizationResult carries the assigned mapId.
        /// For any mapId, constructing a successful result preserves the mapId.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property SuccessfulResult_CarriesCorrectMapId(int mapId)
        {
            var result = new LocalizationResult
            {
                Success = true,
                MapId = mapId,
                Pose = Matrix4x4.identity
            };

            return (result.Success && result.MapId == mapId).ToProperty()
                .Label($"Successful LocalizationResult should carry MapId={mapId}");
        }

        /// <summary>
        /// Property 2b: When localization fails (e.g., null engine causes exception),
        /// OnSuccessfulLocalizations event should NOT be fired.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FailedLocalization_DoesNotFireEvent(PositiveInt width, PositiveInt height, int mapId)
        {
            var localizer = new PointCloudLocalizer(mapId, null, null);
            bool eventFired = false;
            localizer.OnSuccessfulLocalizations += ids => eventFired = true;

            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            // With null engine, Localize catches NullReferenceException and returns Failed
            return (!result.Success && !eventFired).ToProperty()
                .Label($"Failed localization (mapId={mapId}) should not fire OnSuccessfulLocalizations");
        }

        /// <summary>
        /// Property 2c: When localization fails due to invalid dimensions,
        /// OnSuccessfulLocalizations event should NOT be fired.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidDimensions_DoesNotFireEvent(NegativeInt width, PositiveInt height, int mapId)
        {
            var localizer = new PointCloudLocalizer(mapId, null, null);
            bool eventFired = false;
            localizer.OnSuccessfulLocalizations += ids => eventFired = true;

            var data = new StubCameraData(width.Get, height.Get);
            localizer.Localize(data).Wait();

            return (!eventFired).ToProperty()
                .Label($"Invalid dimensions should not fire OnSuccessfulLocalizations");
        }

        // =====================================================================
        // Property 3: 失败的定位结果 Pose 为 identity
        // For any ILocalizationResult where Success is false,
        // Pose should equal Matrix4x4.identity.
        // **Validates: Requirements 3.4**
        // =====================================================================

        /// <summary>
        /// Property 3a: LocalizationResult.Failed() always returns Pose == identity.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FailedFactory_PoseIsIdentity(int iteration)
        {
            var failed = LocalizationResult.Failed();

            return (!failed.Success && failed.Pose == Matrix4x4.identity).ToProperty()
                .Label("LocalizationResult.Failed() should have Success=false and Pose=identity");
        }

        /// <summary>
        /// Property 3b: When Localizer returns a failed result (invalid dimensions),
        /// the Pose is identity.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidDimensions_ResultPoseIsIdentity(NegativeInt width, PositiveInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success && result.Pose == Matrix4x4.identity).ToProperty()
                .Label($"Failed result (Width={width.Get}) should have Pose=identity");
        }

        /// <summary>
        /// Property 3c: When Localizer returns a failed result (null camera data),
        /// the Pose is identity.
        /// </summary>
        [Test]
        public void NullCameraData_ResultPoseIsIdentity()
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var result = localizer.Localize(null).Result;

            Assert.IsFalse(result.Success);
            Assert.AreEqual(Matrix4x4.identity, result.Pose);
        }

        /// <summary>
        /// Property 3d: When Localizer returns a failed result (internal exception),
        /// the Pose is identity.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InternalException_ResultPoseIsIdentity(PositiveInt width, PositiveInt height)
        {
            // null engine with valid dimensions → NullReferenceException caught internally
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success && result.Pose == Matrix4x4.identity).ToProperty()
                .Label("Exception-caused failure should have Pose=identity");
        }

        // =====================================================================
        // Property 15: Localizer 异常捕获
        // For any ICameraData that causes an internal exception in Localizer.Localize(),
        // the method should catch the exception and return Success=false,
        // not propagate it.
        // **Validates: Requirements 9.4**
        // =====================================================================

        /// <summary>
        /// Property 15a: When engine is null and valid camera data is provided,
        /// ProcessFrame throws NullReferenceException which is caught internally.
        /// Localize returns Success=false without propagating the exception.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property NullEngine_ExceptionCaught_ReturnsFailed(PositiveInt width, PositiveInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);

            bool exceptionPropagated = false;
            ILocalizationResult result = null;
            try
            {
                result = localizer.Localize(data).Result;
            }
            catch
            {
                exceptionPropagated = true;
            }

            return (!exceptionPropagated && result != null && !result.Success).ToProperty()
                .Label("Null engine exception should be caught, returning Failed without propagation");
        }

        /// <summary>
        /// Property 15b: After an exception-causing call, the localizer remains usable
        /// for subsequent calls (does not enter a broken state).
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property AfterException_LocalizerRemainsUsable(PositiveInt width, PositiveInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            var data = new StubCameraData(width.Get, height.Get);

            // First call triggers exception (null engine)
            var result1 = localizer.Localize(data).Result;
            // Second call should also work without crashing
            var result2 = localizer.Localize(data).Result;

            return (!result1.Success && !result2.Success).ToProperty()
                .Label("Localizer should remain usable after internal exception");
        }

        /// <summary>
        /// Property 15c: Null camera data does not throw — returns Failed gracefully.
        /// </summary>
        [Test]
        public void NullCameraData_ReturnsFailed()
        {
            var localizer = new PointCloudLocalizer(1, null, null);

            ILocalizationResult result = null;
            Assert.DoesNotThrow(() => result = localizer.Localize(null).Result);
            Assert.IsNotNull(result);
            Assert.IsFalse(result.Success);
        }

        // =====================================================================
        // Property 13: 清理后定位始终失败
        // For any ICameraData, after calling ILocalizer.StopAndCleanUp(),
        // any subsequent Localize() call should return Success=false.
        // **Validates: Requirements 11.2**
        // =====================================================================

        /// <summary>
        /// Property 13: After StopAndCleanUp, Localize always returns Failed.
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property AfterCleanup_LocalizeReturnsFailed(PositiveInt width, PositiveInt height)
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            localizer.StopAndCleanUp().Wait();

            var data = new StubCameraData(width.Get, height.Get);
            var result = localizer.Localize(data).Result;

            return (!result.Success).ToProperty()
                .Label("After StopAndCleanUp, Localize should always return Failed");
        }

        // =====================================================================
        // Property 14: StopAndCleanUp 异常安全
        // For any Localizer instance, even if internal components' Dispose throws
        // an exception, StopAndCleanUp() should not throw to the caller, and
        // subsequent StopAndCleanUp() calls should not cause double-dispose exceptions.
        // **Validates: Requirements 11.4**
        // =====================================================================

        /// <summary>
        /// Property 14a: StopAndCleanUp does not throw on a fresh localizer.
        /// </summary>
        [Test]
        public void StopAndCleanUp_DoesNotThrow()
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            Assert.DoesNotThrow(() => localizer.StopAndCleanUp().Wait());
        }

        /// <summary>
        /// Property 14b: Calling StopAndCleanUp twice does not throw (idempotent, no double-dispose).
        /// </summary>
        [Test]
        public void StopAndCleanUp_CalledTwice_DoesNotThrow()
        {
            var localizer = new PointCloudLocalizer(1, null, null);
            localizer.StopAndCleanUp().Wait();
            Assert.DoesNotThrow(() => localizer.StopAndCleanUp().Wait());
        }
    }
}
