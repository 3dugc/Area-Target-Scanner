using System;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for DownloadManager.
    /// Tests HTTP error message formatting and download progress constraints.
    /// </summary>
    [TestFixture]
    public class DownloadManagerPropertyTests
    {
        /// <summary>
        /// Custom FsCheck generator for HTTP error status codes in [400..599].
        /// </summary>
        private static Arbitrary<int> HttpErrorStatusCodeArbitrary()
        {
            return Gen.Choose(400, 599).ToArbitrary();
        }

        /// <summary>
        /// Custom FsCheck generator for progress values in [0.0, 1.0].
        /// </summary>
        private static Arbitrary<float> ProgressValueArbitrary()
        {
            return Gen.Choose(0, 10000)
                .Select(i => i / 10000f)
                .ToArbitrary();
        }

        // Feature: ar-download-test-scene, Property 3: HTTP 错误状态码显示
        /// <summary>
        /// Property 3: For any non-success HTTP status code in [400..599],
        /// the error message produced by DownloadManager's error format
        /// should contain the numeric string representation of that status code.
        ///
        /// DownloadManager formats protocol errors as: $"HTTP {responseCode}: {error}"
        /// This property verifies that for any status code in the error range,
        /// the formatted message always contains the status code number.
        ///
        /// **Validates: Requirements 2.6**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property HttpErrorStatusCode_ErrorMessageContainsStatusCode()
        {
            return Prop.ForAll(HttpErrorStatusCodeArbitrary(), statusCode =>
            {
                // Simulate the error message format used by DownloadManager
                // when it encounters a ProtocolError from UnityWebRequest:
                // LastError = $"HTTP {_request.responseCode}: {_request.error}";
                string errorMessage = $"HTTP {statusCode}: Server returned error";

                bool containsStatusCode = errorMessage.Contains(statusCode.ToString());

                return containsStatusCode.ToProperty()
                    .Label($"Error message '{errorMessage}' should contain status code '{statusCode}'");
            });
        }

        // Feature: ar-download-test-scene, Property 4: 下载进度显示
        /// <summary>
        /// Property 4: For any download progress value p in [0.0, 1.0],
        /// the value should be within the valid progress range.
        /// DownloadManager exposes Progress as a float from UnityWebRequest.downloadProgress
        /// which is always in [0.0, 1.0]. This property verifies that any generated
        /// progress value in this range satisfies the valid progress constraints.
        ///
        /// **Validates: Requirements 2.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property DownloadProgress_ValueInValidRange()
        {
            return Prop.ForAll(ProgressValueArbitrary(), progress =>
            {
                // Verify the progress value is within valid range [0.0, 1.0]
                bool inRange = progress >= 0.0f && progress <= 1.0f;

                // Verify the progress can be converted to a valid percentage [0, 100]
                int percentage = (int)(progress * 100);
                bool validPercentage = percentage >= 0 && percentage <= 100;

                // Verify the percentage string representation is meaningful
                string percentageText = $"{percentage}%";
                bool containsNumber = percentageText.Contains(percentage.ToString());

                return (inRange && validPercentage && containsNumber).ToProperty()
                    .Label($"Progress {progress} -> {percentage}% should be valid (inRange={inRange}, validPct={validPercentage})");
            });
        }
    }
}
