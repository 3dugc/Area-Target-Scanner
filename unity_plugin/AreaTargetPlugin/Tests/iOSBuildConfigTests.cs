using System.IO;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// iOS 构建配置验证单元测试。
    /// 通过源码检查验证 BuildiOS.cs、iOSPostProcess.cs、build_ios.sh 的关键配置。
    /// Validates: Requirements 4.1, 4.6, 4.7
    /// </summary>
    [TestFixture]
    public class iOSBuildConfigTests
    {
        private string _buildiOSSource;
        private string _postProcessSource;
        private string _buildShellSource;

        [OneTimeSetUp]
        public void OneTimeSetUp()
        {
            // Application.dataPath → unity_project/Assets/
            string editorDir = Path.Combine(Application.dataPath, "Editor");

            string buildPath = Path.Combine(editorDir, "BuildiOS.cs");
            Assert.IsTrue(File.Exists(buildPath), $"BuildiOS.cs not found at {buildPath}");
            _buildiOSSource = File.ReadAllText(buildPath);

            string postProcessPath = Path.Combine(editorDir, "iOSPostProcess.cs");
            Assert.IsTrue(File.Exists(postProcessPath), $"iOSPostProcess.cs not found at {postProcessPath}");
            _postProcessSource = File.ReadAllText(postProcessPath);

            string shellPath = Path.Combine(Application.dataPath, "..", "..", "native_visual_localizer", "build_ios.sh");
            shellPath = Path.GetFullPath(shellPath);
            Assert.IsTrue(File.Exists(shellPath), $"build_ios.sh not found at {shellPath}");
            _buildShellSource = File.ReadAllText(shellPath);
        }

        #region BuildiOS.cs 配置验证 (Requirements 4.1, 4.6, 4.7)

        [Test]
        public void BuildiOS_ScenesArray_ContainsARTestScene()
        {
            // Requirement 4.1: 构建场景列表包含 ARTestScene
            Assert.That(_buildiOSSource, Does.Contain("Assets/Scenes/ARTestScene.unity"),
                "BuildiOS.cs should include ARTestScene.unity in scenes array");
        }

        [Test]
        public void BuildiOS_TargetOSVersion_Is16()
        {
            // Requirement 4.6: targetOSVersionString = "16.0"
            Assert.That(_buildiOSSource, Does.Contain("targetOSVersionString = \"16.0\""),
                "BuildiOS.cs should set targetOSVersionString to 16.0");
        }

        [Test]
        public void BuildiOS_CameraUsageDescription_IsNonEmpty()
        {
            // Requirement 4.7: cameraUsageDescription 非空
            Assert.That(_buildiOSSource, Does.Contain("cameraUsageDescription ="),
                "BuildiOS.cs should set cameraUsageDescription");
            // 确认不是空字符串赋值
            Assert.That(_buildiOSSource, Does.Not.Contain("cameraUsageDescription = \"\""),
                "cameraUsageDescription should not be empty string");
        }

        #endregion

        #region iOSPostProcess.cs 配置验证 (Requirements 4.2, 4.3, 4.4, 4.5)

        [Test]
        public void PostProcess_AddsAccelerateFramework()
        {
            Assert.That(_postProcessSource, Does.Contain("Accelerate.framework"),
                "iOSPostProcess.cs should add Accelerate.framework");
        }

        [Test]
        public void PostProcess_AddsCoreMediaFramework()
        {
            Assert.That(_postProcessSource, Does.Contain("CoreMedia.framework"),
                "iOSPostProcess.cs should add CoreMedia.framework");
        }

        [Test]
        public void PostProcess_AddsCoreVideoFramework()
        {
            Assert.That(_postProcessSource, Does.Contain("CoreVideo.framework"),
                "iOSPostProcess.cs should add CoreVideo.framework");
        }

        [Test]
        public void PostProcess_DisablesBitcode()
        {
            // Requirement 4.4: ENABLE_BITCODE = NO
            Assert.That(_postProcessSource, Does.Contain("ENABLE_BITCODE"),
                "iOSPostProcess.cs should reference ENABLE_BITCODE");
            Assert.That(_postProcessSource, Does.Contain("\"NO\""),
                "iOSPostProcess.cs should set ENABLE_BITCODE to NO");
        }

        [Test]
        public void PostProcess_AddsStdCppLinkerFlag()
        {
            // Requirement 4.5: -lstdc++
            Assert.That(_postProcessSource, Does.Contain("-lstdc++"),
                "iOSPostProcess.cs should add -lstdc++ linker flag");
        }

        [Test]
        public void PostProcess_CopiesOpenCVFramework()
        {
            // Requirement 4.2: opencv2.framework 复制逻辑
            Assert.That(_postProcessSource, Does.Contain("opencv2.framework"),
                "iOSPostProcess.cs should handle opencv2.framework copy");
        }

        #endregion

        #region build_ios.sh 配置验证 (Requirement 4.9)

        [Test]
        public void BuildShell_VerifiesArm64Architecture()
        {
            // Requirement 4.9: 通过统一的原生库契约脚本验证 arm64 和导出符号
            Assert.That(_buildShellSource, Does.Contain("check_native_symbols.sh"),
                "build_ios.sh should invoke the centralized native contract check");
        }

        #endregion
    }
}
