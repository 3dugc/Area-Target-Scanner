using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Callbacks;
using UnityEngine;
using PackageInfo = UnityEditor.PackageManager.PackageInfo;
#if UNITY_IOS
using UnityEditor.iOS.Xcode;
#endif

namespace AreaTargetPlugin.Editor
{
    /// <summary>
    /// Adds the native Area Target dependencies from this installed UPM package to
    /// an iOS Xcode export. The package is the only source of these artifacts;
    /// this callback deliberately does not look in the host Unity project.
    /// </summary>
    public static class iOSPostProcess
    {
        private const string StaticLibraryRelativePath = "Runtime/Plugins/iOS/libvisual_localizer.a";
        private const string OpenCvFrameworkRelativePath = "Runtime/Plugins/iOS/opencv2.framework";
        private const string XcodeFrameworkRelativePath = "Frameworks/opencv2.framework";

        [PostProcessBuild(100)]
        public static void OnPostProcessBuild(BuildTarget target, string pathToBuiltProject)
        {
            if (target != BuildTarget.iOS)
                return;

#if UNITY_IOS
            string packageRoot = GetPackageRoot();
            string staticLibraryPath = Path.Combine(packageRoot, StaticLibraryRelativePath);
            string openCvFrameworkPath = Path.Combine(packageRoot, OpenCvFrameworkRelativePath);
            ValidateArtifacts(staticLibraryPath, openCvFrameworkPath);

            string projectPath = PBXProject.GetPBXProjectPath(pathToBuiltProject);
            var project = new PBXProject();
            project.ReadFromFile(projectPath);

            string targetGuid = project.GetUnityFrameworkTargetGuid();
            if (string.IsNullOrEmpty(targetGuid))
                targetGuid = project.GetUnityMainTargetGuid();
            if (string.IsNullOrEmpty(targetGuid))
                throw new BuildFailedException("Area Target iOS postprocess could not resolve a Unity Xcode target.");

            string destinationFramework = Path.Combine(pathToBuiltProject, XcodeFrameworkRelativePath);
            if (!Directory.Exists(destinationFramework))
                CopyDirectory(openCvFrameworkPath, destinationFramework);

            string frameworkGuid = project.AddFile(
                XcodeFrameworkRelativePath,
                XcodeFrameworkRelativePath,
                PBXSourceTree.Source);
            project.AddFileToBuild(targetGuid, frameworkGuid);
            project.AddBuildProperty(targetGuid, "FRAMEWORK_SEARCH_PATHS", "$(PROJECT_DIR)/Frameworks");

            AddRequiredSystemFrameworks(project, targetGuid);
            project.AddBuildProperty(targetGuid, "OTHER_LDFLAGS", "-lc++");
            project.AddBuildProperty(targetGuid, "OTHER_LDFLAGS", "-lz");
            project.AddBuildProperty(targetGuid, "OTHER_LDFLAGS", "-lsqlite3");
            project.SetBuildProperty(targetGuid, "ENABLE_BITCODE", "NO");
            project.WriteToFile(projectPath);

            Debug.Log(
                "[AreaTargetPlugin] Validated UPM-owned libvisual_localizer.a and added the "
                + "opencv2.framework dependency to the iOS Xcode export.");
#else
            throw new BuildFailedException(
                "Area Target iOS postprocess requires the Unity iOS Build Support module.");
#endif
        }

        private static string GetPackageRoot()
        {
            PackageInfo package = PackageInfo.FindForAssembly(typeof(iOSPostProcess).Assembly);
            if (package == null || string.IsNullOrWhiteSpace(package.resolvedPath))
            {
                throw new BuildFailedException(
                    "Area Target iOS postprocess could not resolve its installed UPM package path.");
            }

            return package.resolvedPath;
        }

        private static void ValidateArtifacts(string staticLibraryPath, string openCvFrameworkPath)
        {
            if (!File.Exists(staticLibraryPath))
            {
                throw new BuildFailedException(
                    "Area Target iOS static library is missing from the installed package: "
                    + StaticLibraryRelativePath);
            }

            if (!Directory.Exists(openCvFrameworkPath))
            {
                throw new BuildFailedException(
                    "Area Target OpenCV framework is missing from the installed package: "
                    + OpenCvFrameworkRelativePath);
            }
        }

#if UNITY_IOS
        private static void AddRequiredSystemFrameworks(PBXProject project, string targetGuid)
        {
            foreach (string framework in new[]
            {
                "ARKit.framework",
                "AVFoundation.framework",
                "Accelerate.framework",
                "CoreGraphics.framework",
                "CoreMedia.framework",
                "CoreMotion.framework",
                "CoreVideo.framework",
                "Metal.framework",
                "MetalKit.framework",
                "UIKit.framework"
            })
            {
                project.AddFrameworkToProject(targetGuid, framework, false);
            }
        }
#endif

        private static void CopyDirectory(string sourceDirectory, string destinationDirectory)
        {
            Directory.CreateDirectory(destinationDirectory);
            foreach (string file in Directory.GetFiles(sourceDirectory))
            {
                string destinationFile = Path.Combine(destinationDirectory, Path.GetFileName(file));
                File.Copy(file, destinationFile, true);
            }

            foreach (string directory in Directory.GetDirectories(sourceDirectory))
            {
                string destination = Path.Combine(destinationDirectory, Path.GetFileName(directory));
                CopyDirectory(directory, destination);
            }
        }
    }
}
