using System;
using System.Reflection;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using UnityEngine.UI;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for SLAMDebugPanel.
    /// Tests tracking state to display mapping and asset info display completeness.
    /// </summary>
    [TestFixture]
    public class SLAMDebugPanelPropertyTests
    {
        private GameObject _panelGo;
        private SLAMDebugPanel _debugPanel;
        private Text _statusText;
        private Text _assetInfoText;

        [SetUp]
        public void SetUp()
        {
            _panelGo = new GameObject("SLAMDebugPanel");
            _debugPanel = _panelGo.AddComponent<SLAMDebugPanel>();

            // Create Text components on child GameObjects
            var statusGo = new GameObject("StatusText");
            _statusText = statusGo.AddComponent<Text>();

            var assetInfoGo = new GameObject("AssetInfoText");
            _assetInfoText = assetInfoGo.AddComponent<Text>();

            // Use reflection to assign private [SerializeField] fields
            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);
        }

        [TearDown]
        public void TearDown()
        {
            if (_panelGo != null) UnityEngine.Object.DestroyImmediate(_panelGo);
            if (_statusText != null) UnityEngine.Object.DestroyImmediate(_statusText.gameObject);
            if (_assetInfoText != null) UnityEngine.Object.DestroyImmediate(_assetInfoText.gameObject);
        }

        /// <summary>
        /// Helper to set a private field on a MonoBehaviour via reflection.
        /// </summary>
        private static void SetPrivateField(object target, string fieldName, object value)
        {
            var field = target.GetType().GetField(fieldName,
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (field == null)
                throw new InvalidOperationException($"Field '{fieldName}' not found on {target.GetType().Name}");
            field.SetValue(target, value);
        }

        /// <summary>
        /// FsCheck generator for non-null, non-empty asset name strings.
        /// </summary>
        private static Arbitrary<string> NonEmptyStringArbitrary()
        {
            return Arb.Default.NonEmptyString()
                .Generator
                .Select(s => s.Get)
                .ToArbitrary();
        }

        /// <summary>
        /// FsCheck generator for non-negative keyframe counts.
        /// </summary>
        private static Arbitrary<int> KeyframeCountArbitrary()
        {
            return Gen.Choose(0, 100000).ToArbitrary();
        }

        // Feature: ar-slam-test-scene, Property 1: 跟踪状态到显示的映射
        /// <summary>
        /// Property 1: For each TrackingState (INITIALIZING, TRACKING, LOST),
        /// calling SetStatus with the corresponding message and color should
        /// set the correct text content and color on statusText:
        ///   - INITIALIZING → text "正在初始化", color = yellow
        ///   - TRACKING → text "跟踪中", color = green
        ///   - LOST → text "跟踪丢失", color = red
        ///
        /// This tests that SLAMDebugPanel.SetStatus correctly applies the text and color
        /// for each tracking state mapping defined in the design.
        ///
        /// **Validates: Requirements 3.1, 3.2, 3.3, 3.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property TrackingState_MapsToCorrectTextAndColor()
        {
            var stateGen = Gen.Elements(
                TrackingState.INITIALIZING,
                TrackingState.TRACKING,
                TrackingState.LOST
            ).ToArbitrary();

            return Prop.ForAll(stateGen, (TrackingState state) =>
            {
                string expectedMessage;
                Color expectedColor;

                switch (state)
                {
                    case TrackingState.INITIALIZING:
                        expectedMessage = "正在初始化";
                        expectedColor = Color.yellow;
                        break;
                    case TrackingState.TRACKING:
                        expectedMessage = "跟踪中";
                        expectedColor = Color.green;
                        break;
                    case TrackingState.LOST:
                        expectedMessage = "跟踪丢失";
                        expectedColor = Color.red;
                        break;
                    default:
                        throw new ArgumentOutOfRangeException();
                }

                // Call SetStatus as the caller (SLAMTestSceneManager) would
                _debugPanel.SetStatus(expectedMessage, expectedColor);

                string actualText = _statusText.text;
                Color actualColor = _statusText.color;

                bool textCorrect = actualText == expectedMessage;
                bool colorCorrect = actualColor == expectedColor;

                return (textCorrect && colorCorrect)
                    .ToProperty()
                    .Label($"State={state}: text='{actualText}' (expected '{expectedMessage}', match={textCorrect}), " +
                           $"color={actualColor} (expected {expectedColor}, match={colorCorrect})");
            });
        }

        // Feature: ar-slam-test-scene, Property 6: 資産包信息显示完整性
        /// <summary>
        /// Property 6: For any valid asset name, version, and keyframeCount,
        /// calling SetAssetInfo should result in assetInfoText.text containing
        /// all three field values as string representations.
        ///
        /// The SLAMDebugPanel formats asset info as:
        ///   "资产: {name} | 版本: {version} | 关键帧: {keyframeCount}"
        /// This property verifies that all three values appear in the output text.
        ///
        /// **Validates: Requirements 2.6**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property AssetInfo_DisplayContainsAllFields()
        {
            return Prop.ForAll(
                NonEmptyStringArbitrary(),
                NonEmptyStringArbitrary(),
                KeyframeCountArbitrary(),
                (string name, string version, int keyframeCount) =>
                {
                    _debugPanel.SetAssetInfo(name, version, keyframeCount);

                    string text = _assetInfoText.text;

                    bool containsName = text.Contains(name);
                    bool containsVersion = text.Contains(version);
                    bool containsKeyframeCount = text.Contains(keyframeCount.ToString());

                    return (containsName && containsVersion && containsKeyframeCount)
                        .ToProperty()
                        .Label($"AssetInfo text '{text}' should contain " +
                               $"name='{name}' ({containsName}), " +
                               $"version='{version}' ({containsVersion}), " +
                               $"keyframeCount='{keyframeCount}' ({containsKeyframeCount})");
                });
        }
    }
}
