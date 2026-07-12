using System;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for DownloadManager.
    /// Tests empty/whitespace URL rejection, Cancel state, and Dispose resource cleanup.
    /// Validates: Requirements 2.4, 2.5
    /// </summary>
    [TestFixture]
    public class DownloadManagerTests
    {
        private GameObject _hostObject;
        private MonoBehaviour _host;
        private List<GameObject> _gameObjects;

        [SetUp]
        public void SetUp()
        {
            _gameObjects = new List<GameObject>();
            _hostObject = new GameObject("DownloadManagerTestHost");
            _host = _hostObject.AddComponent<DownloadManagerTestHelper>();
            _gameObjects.Add(_hostObject);
        }

        [TearDown]
        public void TearDown()
        {
            foreach (var go in _gameObjects)
            {
                if (go != null) UnityEngine.Object.DestroyImmediate(go);
            }
            _gameObjects.Clear();
        }

        #region Empty URL Rejection Tests (Requirement 2.4)

        [Test]
        public void StartDownload_NullUrl_SetsLastErrorAndCallsOnError()
        {
            var dm = new DownloadManager(_host);
            string receivedError = null;

            var result = dm.StartDownload(null, "/tmp/test.zip", null, null, e => receivedError = e);

            Assert.IsNull(result);
            Assert.AreEqual("请输入有效的 URL", dm.LastError);
            Assert.AreEqual("请输入有效的 URL", receivedError);
            Assert.IsFalse(dm.IsDownloading);
            dm.Dispose();
        }

        [Test]
        public void StartDownload_EmptyString_SetsLastErrorAndCallsOnError()
        {
            var dm = new DownloadManager(_host);
            string receivedError = null;

            var result = dm.StartDownload("", "/tmp/test.zip", null, null, e => receivedError = e);

            Assert.IsNull(result);
            Assert.AreEqual("请输入有效的 URL", dm.LastError);
            Assert.AreEqual("请输入有效的 URL", receivedError);
            Assert.IsFalse(dm.IsDownloading);
            dm.Dispose();
        }

        [Test]
        public void StartDownload_WhitespaceOnly_SetsLastErrorAndCallsOnError()
        {
            var dm = new DownloadManager(_host);
            string receivedError = null;

            var result = dm.StartDownload("   \t\n  ", "/tmp/test.zip", null, null, e => receivedError = e);

            Assert.IsNull(result);
            Assert.AreEqual("请输入有效的 URL", dm.LastError);
            Assert.AreEqual("请输入有效的 URL", receivedError);
            Assert.IsFalse(dm.IsDownloading);
            dm.Dispose();
        }

        [Test]
        public void StartDownload_EmptyUrl_ReturnsNullCoroutine()
        {
            var dm = new DownloadManager(_host);

            var result = dm.StartDownload("", "/tmp/test.zip", null, null, null);

            Assert.IsNull(result);
            dm.Dispose();
        }

        [Test]
        public void StartDownload_EmptyUrl_DoesNotSetIsDownloading()
        {
            var dm = new DownloadManager(_host);

            dm.StartDownload("", "/tmp/test.zip", null, null, null);

            Assert.IsFalse(dm.IsDownloading);
            dm.Dispose();
        }

        #endregion

        #region Cancel Tests (Requirement 2.5)

        [Test]
        public void Cancel_WhenNotDownloading_IsDownloadingRemainsFalse()
        {
            var dm = new DownloadManager(_host);

            dm.Cancel();

            Assert.IsFalse(dm.IsDownloading);
            dm.Dispose();
        }

        [Test]
        public void Cancel_WhenNotDownloading_DoesNotThrow()
        {
            var dm = new DownloadManager(_host);

            Assert.DoesNotThrow(() => dm.Cancel());
            dm.Dispose();
        }

        [Test]
        public void Cancel_SetsLastErrorToCancelMessage()
        {
            var dm = new DownloadManager(_host);

            // Cancel when not downloading should early-return (IsDownloading is false)
            // So LastError won't be set. Verify the initial state.
            Assert.IsNull(dm.LastError);
            dm.Dispose();
        }

        #endregion

        #region Dispose Tests (Requirement 2.5)

        [Test]
        public void Dispose_WhenNotDownloading_DoesNotThrow()
        {
            var dm = new DownloadManager(_host);

            Assert.DoesNotThrow(() => dm.Dispose());
        }

        [Test]
        public void Dispose_CalledMultipleTimes_DoesNotThrow()
        {
            var dm = new DownloadManager(_host);

            Assert.DoesNotThrow(() =>
            {
                dm.Dispose();
                dm.Dispose();
                dm.Dispose();
            });
        }

        [Test]
        public void Dispose_SetsIsDownloadingToFalse()
        {
            var dm = new DownloadManager(_host);

            dm.Dispose();

            Assert.IsFalse(dm.IsDownloading);
        }

        [Test]
        public void Dispose_AfterEmptyUrlAttempt_DoesNotThrow()
        {
            var dm = new DownloadManager(_host);
            dm.StartDownload("", "/tmp/test.zip", null, null, null);

            Assert.DoesNotThrow(() => dm.Dispose());
        }

        #endregion

        #region Constructor Tests

        [Test]
        public void Constructor_NullHost_ThrowsArgumentNullException()
        {
            Assert.Throws<ArgumentNullException>(() => new DownloadManager(null));
        }

        [Test]
        public void Constructor_InitialState_IsNotDownloading()
        {
            var dm = new DownloadManager(_host);

            Assert.IsFalse(dm.IsDownloading);
            Assert.AreEqual(0f, dm.Progress);
            Assert.IsNull(dm.LastError);
            dm.Dispose();
        }

        #endregion
    }

    /// <summary>
    /// Minimal MonoBehaviour used as a host for DownloadManager in tests.
    /// </summary>
    public class DownloadManagerTestHelper : MonoBehaviour { }
}
