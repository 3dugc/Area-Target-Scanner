using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for SLAMAudioFeedback.
    /// Tests null-safety: calling PlayTrackingFound/PlayTrackingLost does not throw
    /// when AudioClip or AudioSource is null.
    /// Validates: Requirements 6.1, 6.3
    /// </summary>
    [TestFixture]
    public class SLAMAudioFeedbackTests
    {
        private GameObject _feedbackGo;
        private SLAMAudioFeedback _audioFeedback;
        private GameObject _audioSourceGo;

        [SetUp]
        public void SetUp()
        {
            _feedbackGo = new GameObject("SLAMAudioFeedback");
            _audioFeedback = _feedbackGo.AddComponent<SLAMAudioFeedback>();
            _audioSourceGo = null;
        }

        [TearDown]
        public void TearDown()
        {
            if (_feedbackGo != null) UnityEngine.Object.DestroyImmediate(_feedbackGo);
            if (_audioSourceGo != null) UnityEngine.Object.DestroyImmediate(_audioSourceGo);
        }

        private static void SetPrivateField(object target, string fieldName, object value)
        {
            var field = target.GetType().GetField(fieldName,
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (field == null)
                throw new InvalidOperationException($"Field '{fieldName}' not found on {target.GetType().Name}");
            field.SetValue(target, value);
        }

        #region Null AudioClip Tests (Requirement 6.1, 6.3)

        [Test]
        public void PlayTrackingFound_NullAudioClip_DoesNotThrow()
        {
            _audioSourceGo = new GameObject("AudioSource");
            var audioSource = _audioSourceGo.AddComponent<AudioSource>();
            SetPrivateField(_audioFeedback, "audioSource", audioSource);
            // trackingFoundClip left as null

            Assert.DoesNotThrow(() => _audioFeedback.PlayTrackingFound());
        }

        [Test]
        public void PlayTrackingLost_NullAudioClip_DoesNotThrow()
        {
            _audioSourceGo = new GameObject("AudioSource");
            var audioSource = _audioSourceGo.AddComponent<AudioSource>();
            SetPrivateField(_audioFeedback, "audioSource", audioSource);
            // trackingLostClip left as null

            Assert.DoesNotThrow(() => _audioFeedback.PlayTrackingLost());
        }

        #endregion

        #region Null AudioSource Tests (Requirement 6.1, 6.3)

        [Test]
        public void PlayTrackingFound_NullAudioSource_DoesNotThrow()
        {
            // audioSource left as null (not set via reflection)

            Assert.DoesNotThrow(() => _audioFeedback.PlayTrackingFound());
        }

        [Test]
        public void PlayTrackingLost_NullAudioSource_DoesNotThrow()
        {
            // audioSource left as null (not set via reflection)

            Assert.DoesNotThrow(() => _audioFeedback.PlayTrackingLost());
        }

        #endregion
    }
}
