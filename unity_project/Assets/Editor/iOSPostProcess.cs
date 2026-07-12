using UnityEditor;
using UnityEditor.Callbacks;
using UnityEngine;
#if UNITY_IOS
using UnityEditor.iOS.Xcode;
#endif
using System.IO;

/// <summary>
/// iOS 构建后处理：添加 OpenCV framework 链接和搜索路径。
/// libvisual_localizer.a 依赖 opencv2.framework，需要在 Xcode 项目中配置。
/// </summary>
public class iOSPostProcess
{
    [PostProcessBuild(100)]
    public static void OnPostProcessBuild(BuildTarget target, string pathToBuiltProject)
    {
        if (target != BuildTarget.iOS) return;

#if UNITY_IOS
        string projPath = PBXProject.GetPBXProjectPath(pathToBuiltProject);
        var proj = new PBXProject();
        proj.ReadFromFile(projPath);

        // Unity 2019.3+ uses UnityFramework target for plugins
        string targetGuid = proj.GetUnityFrameworkTargetGuid();
        if (string.IsNullOrEmpty(targetGuid))
            targetGuid = proj.GetUnityMainTargetGuid();

        // 1. Add framework search path pointing to where opencv2.framework lives
        //    User must copy opencv2.framework to the Xcode project or set this path.
        //    We'll add a relative path that can be overridden.
        string opencvFrameworkPath = GetOpenCVFrameworkPath();
        if (!string.IsNullOrEmpty(opencvFrameworkPath))
        {
            proj.AddFrameworkToProject(targetGuid, "opencv2.framework", false);
            proj.AddBuildProperty(targetGuid, "FRAMEWORK_SEARCH_PATHS", opencvFrameworkPath);
            Debug.Log($"[iOSPostProcess] Added opencv2.framework search path: {opencvFrameworkPath}");
        }

        // 2. Copy opencv2.framework into Xcode project if it exists at known location
        string srcFramework = Path.GetFullPath(
            Path.Combine(Application.dataPath, "../../native_visual_localizer/opencv_ios/opencv2.framework"));
        string destFramework = Path.Combine(pathToBuiltProject, "Frameworks/opencv2.framework");

        if (Directory.Exists(srcFramework) && !Directory.Exists(destFramework))
        {
            Debug.Log($"[iOSPostProcess] Copying opencv2.framework to Xcode project...");
            CopyDirectory(srcFramework, destFramework);

            // Add to Xcode project
            string fileGuid = proj.AddFile(
                "Frameworks/opencv2.framework",
                "Frameworks/opencv2.framework",
                PBXSourceTree.Source);
            proj.AddFileToBuild(targetGuid, fileGuid);
            proj.AddBuildProperty(targetGuid, "FRAMEWORK_SEARCH_PATHS", "$(PROJECT_DIR)/Frameworks");
            Debug.Log("[iOSPostProcess] opencv2.framework copied and added to Xcode project");
        }
        else if (!Directory.Exists(srcFramework))
        {
            Debug.LogWarning($"[iOSPostProcess] opencv2.framework not found at {srcFramework}");
            Debug.LogWarning("[iOSPostProcess] You must manually add opencv2.framework to the Xcode project");
            // Still add the search path for manual setup
            proj.AddBuildProperty(targetGuid, "FRAMEWORK_SEARCH_PATHS", "$(PROJECT_DIR)/Frameworks");
        }

        // 3. Add required system frameworks
        proj.AddFrameworkToProject(targetGuid, "Accelerate.framework", false);
        proj.AddFrameworkToProject(targetGuid, "CoreMedia.framework", false);
        proj.AddFrameworkToProject(targetGuid, "CoreVideo.framework", false);
        proj.AddFrameworkToProject(targetGuid, "AssetsLibrary.framework", true); // weak

        // 4. Ensure C++ standard library is linked
        proj.AddBuildProperty(targetGuid, "OTHER_LDFLAGS", "-lstdc++");

        // 5. Disable bitcode (OpenCV doesn't support it)
        proj.SetBuildProperty(targetGuid, "ENABLE_BITCODE", "NO");

        proj.WriteToFile(projPath);
        Debug.Log("[iOSPostProcess] Xcode project updated for OpenCV + libvisual_localizer");
#else
        Debug.Log("[iOSPostProcess] Skipped (not iOS build module)");
#endif
    }

    private static string GetOpenCVFrameworkPath()
    {
        // Check common locations
        string[] candidates = {
            Path.GetFullPath(Path.Combine(Application.dataPath, "../../native_visual_localizer/opencv_ios")),
            Path.GetFullPath(Path.Combine(Application.dataPath, "../Frameworks")),
        };

        foreach (var path in candidates)
        {
            if (Directory.Exists(Path.Combine(path, "opencv2.framework")))
                return path;
        }
        return null;
    }

    private static void CopyDirectory(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.GetFiles(src))
        {
            string destFile = Path.Combine(dst, Path.GetFileName(file));
            File.Copy(file, destFile, true);
        }
        foreach (var dir in Directory.GetDirectories(src))
        {
            string destDir = Path.Combine(dst, Path.GetFileName(dir));
            CopyDirectory(dir, destDir);
        }
    }
}
