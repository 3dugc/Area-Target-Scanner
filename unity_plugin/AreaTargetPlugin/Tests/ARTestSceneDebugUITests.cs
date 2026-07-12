using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// ARTestSceneManager 调试 UI 单元测试。
    /// 测试 FormatQualityText、GetQualityColor、FormatTrackingDebugText 的行为。
    /// Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6
    /// </summary>
    [TestFixture]
    public class ARTestSceneDebugUITests
    {
        #region FormatQualityText Tests (Requirements 3.1, 3.2)

        [Test]
        public void FormatQualityText_Localized_ContainsAlignedAndLocalized()
        {
            string result = ARTestSceneManager.FormatQualityText(LocalizationQuality.LOCALIZED);

            Assert.That(result, Does.Contain("Aligned"),
                "LOCALIZED quality should show 'Aligned' mode");
            Assert.That(result, Does.Contain("LOCALIZED"),
                "LOCALIZED quality should include 'LOCALIZED' text");
        }

        [Test]
        public void FormatQualityText_Recognized_ContainsRawAndRecognized()
        {
            string result = ARTestSceneManager.FormatQualityText(LocalizationQuality.RECOGNIZED);

            Assert.That(result, Does.Contain("Raw"),
                "RECOGNIZED quality should show 'Raw' mode");
            Assert.That(result, Does.Contain("RECOGNIZED"),
                "RECOGNIZED quality should include 'RECOGNIZED' text");
        }

        [Test]
        public void FormatQualityText_None_ContainsRawAndNone()
        {
            string result = ARTestSceneManager.FormatQualityText(LocalizationQuality.NONE);

            Assert.That(result, Does.Contain("Raw"),
                "NONE quality should show 'Raw' mode");
            Assert.That(result, Does.Contain("NONE"),
                "NONE quality should include 'NONE' text");
        }

        #endregion

        #region GetQualityColor Tests (Requirements 3.3, 3.4)

        [Test]
        public void GetQualityColor_Localized_ReturnsGreen()
        {
            Color result = ARTestSceneManager.GetQualityColor(LocalizationQuality.LOCALIZED);
            Assert.AreEqual(Color.green, result, "LOCALIZED should map to green");
        }

        [Test]
        public void GetQualityColor_Recognized_ReturnsYellow()
        {
            Color result = ARTestSceneManager.GetQualityColor(LocalizationQuality.RECOGNIZED);
            Assert.AreEqual(Color.yellow, result, "RECOGNIZED should map to yellow");
        }

        [Test]
        public void GetQualityColor_None_ReturnsRed()
        {
            Color result = ARTestSceneManager.GetQualityColor(LocalizationQuality.NONE);
            Assert.AreEqual(Color.red, result, "NONE should map to red");
        }

        #endregion

        #region FormatTrackingDebugText Tests (Requirements 3.5, 3.6)

        [Test]
        public void FormatTrackingDebugText_TrackingData_ContainsAllFieldLabels()
        {
            string result = ARTestSceneManager.FormatTrackingDebugText(
                confidence: 0.85f,
                matchedFeatures: 120,
                frameCount: 42,
                currentMode: LocalizationMode.Aligned,
                quality: LocalizationQuality.LOCALIZED,
                akazeTriggered: 0,
                consistencyRejected: 0);

            Assert.That(result, Does.Contain("置信度"), "Should contain '置信度' label");
            Assert.That(result, Does.Contain("特征点"), "Should contain '特征点' label");
            Assert.That(result, Does.Contain("帧"), "Should contain '帧' label");
            Assert.That(result, Does.Contain("模式"), "Should contain '模式' label");
            Assert.That(result, Does.Contain("质量"), "Should contain '质量' label");
            Assert.That(result, Does.Contain("AKAZE"), "Should contain 'AKAZE' label");
            Assert.That(result, Does.Contain("一致性"), "Should contain '一致性' label");
        }

        [Test]
        public void FormatTrackingDebugText_AkazeTriggered_ContainsTriggeredText()
        {
            string result = ARTestSceneManager.FormatTrackingDebugText(
                confidence: 0.5f,
                matchedFeatures: 50,
                frameCount: 10,
                currentMode: LocalizationMode.Raw,
                quality: LocalizationQuality.RECOGNIZED,
                akazeTriggered: 1,
                consistencyRejected: 0);

            Assert.That(result, Does.Contain("触发"),
                "akaze_triggered=1 should show '触发'");
        }

        [Test]
        public void FormatTrackingDebugText_AkazeNotTriggered_ContainsNotTriggeredText()
        {
            string result = ARTestSceneManager.FormatTrackingDebugText(
                confidence: 0.5f,
                matchedFeatures: 50,
                frameCount: 10,
                currentMode: LocalizationMode.Raw,
                quality: LocalizationQuality.RECOGNIZED,
                akazeTriggered: 0,
                consistencyRejected: 0);

            Assert.That(result, Does.Contain("未触发"),
                "akaze_triggered=0 should show '未触发'");
        }

        [Test]
        public void FormatTrackingDebugText_ConsistencyRejected_ContainsRejectedText()
        {
            string result = ARTestSceneManager.FormatTrackingDebugText(
                confidence: 0.5f,
                matchedFeatures: 50,
                frameCount: 10,
                currentMode: LocalizationMode.Raw,
                quality: LocalizationQuality.NONE,
                akazeTriggered: 0,
                consistencyRejected: 1);

            Assert.That(result, Does.Contain("拒绝"),
                "consistency_rejected=1 should show '拒绝'");
        }

        [Test]
        public void FormatTrackingDebugText_ConsistencyPassed_ContainsPassedText()
        {
            string result = ARTestSceneManager.FormatTrackingDebugText(
                confidence: 0.5f,
                matchedFeatures: 50,
                frameCount: 10,
                currentMode: LocalizationMode.Raw,
                quality: LocalizationQuality.RECOGNIZED,
                akazeTriggered: 0,
                consistencyRejected: 0);

            Assert.That(result, Does.Contain("通过"),
                "consistency_rejected=0 should show '通过'");
        }

        #endregion
    }
}
