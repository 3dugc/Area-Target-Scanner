using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// iOS 构建脚本：支持命令行和菜单栏触发构建。
/// 命令行用法: Unity -batchmode -executeMethod BuildiOS.Build -projectPath ./unity_project
/// </summary>
public class BuildiOS
{
    [MenuItem("Build/Build iOS")]
    public static void Build()
    {
        var scenes = new[]
        {
            "Assets/Scenes/SLAMTestScene.unity",
            "Assets/Scenes/TestScene.unity",
            "Assets/Scenes/ARTestScene.unity"
        };

        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = "Builds/iOS",
            target = BuildTarget.iOS,
            options = BuildOptions.None
        };

        // 确保 iOS 平台设置
        PlayerSettings.iOS.targetDevice = iOSTargetDevice.iPhoneAndiPad;
        PlayerSettings.iOS.targetOSVersionString = "16.0";
        PlayerSettings.iOS.cameraUsageDescription = "Required for AR area target tracking";
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.iOS, "com.areatarget.test");

        // 确保 XRGeneralSettingsPerBuildTarget 在 preloadedAssets 中
        EnsureXRPreloadedAssets();

        BuildReport report = BuildPipeline.BuildPlayer(options);
        BuildSummary summary = report.summary;

        if (summary.result == BuildResult.Succeeded)
        {
            Debug.Log($"[BuildiOS] 构建成功: {summary.totalSize / (1024 * 1024):F1} MB, 耗时 {summary.totalTime.TotalSeconds:F1}s");
        }
        else
        {
            Debug.LogError($"[BuildiOS] 构建失败: {summary.result}");
            foreach (var step in report.steps)
            {
                foreach (var msg in step.messages)
                {
                    if (msg.type == LogType.Error || msg.type == LogType.Warning)
                        Debug.LogError($"  {msg.content}");
                }
            }
        }
    }

    [MenuItem("Build/Build iOS (Development)")]
    public static void BuildDevelopment()
    {
        var scenes = new[]
        {
            "Assets/Scenes/TestScene.unity",
            "Assets/Scenes/ARTestScene.unity"
        };

        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = "Builds/iOS_Dev",
            target = BuildTarget.iOS,
            options = BuildOptions.Development | BuildOptions.AllowDebugging
        };

        PlayerSettings.iOS.targetDevice = iOSTargetDevice.iPhoneAndiPad;
        PlayerSettings.iOS.targetOSVersionString = "16.0";
        PlayerSettings.iOS.cameraUsageDescription = "Required for AR area target tracking";

        BuildReport report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result == BuildResult.Succeeded)
            Debug.Log("[BuildiOS] Development 构建成功");
        else
            Debug.LogError("[BuildiOS] Development 构建失败");
    }

    /// <summary>
    /// 确保运行时 XRGeneralSettings 资产在 preloadedAssets 中。
    /// 注意：必须添加的是运行时类型 XRGeneralSettings（不是 Editor-only 的 XRGeneralSettingsPerBuildTarget），
    /// 因为 XRGeneralSettings.Awake() 会设置 s_RuntimeSettingsInstance = this，
    /// 这是 XRGeneralSettings.Instance 在 Player 中不为 NULL 的唯一途径。
    /// </summary>
    private static void EnsureXRPreloadedAssets()
    {
        // 加载运行时 XRGeneralSettings_iOS 资产（这是 Player 构建中实际需要的）
        var xrGeneralSettings = AssetDatabase.LoadAssetAtPath<Object>("Assets/XR/Settings/XRGeneralSettings_iOS.asset");
        if (xrGeneralSettings == null)
        {
            Debug.LogWarning("[BuildiOS] XRGeneralSettings_iOS.asset 未找到");
            return;
        }

        Debug.Log($"[BuildiOS] XRGeneralSettings_iOS 类型: {xrGeneralSettings.GetType().FullName}");

        var preloaded = PlayerSettings.GetPreloadedAssets().ToList();

        // 移除旧的 Editor-only XRGeneralSettingsPerBuildTarget（如果存在）
        var perBuildTarget = AssetDatabase.LoadAssetAtPath<Object>("Assets/XR/XRGeneralSettingsPerBuildTarget.asset");
        if (perBuildTarget != null)
        {
            int removed = preloaded.RemoveAll(a => a != null && a == perBuildTarget);
            if (removed > 0)
                Debug.Log($"[BuildiOS] 已从 preloadedAssets 移除 Editor-only XRGeneralSettingsPerBuildTarget ({removed} 项)");
        }

        // 清理 null 引用
        preloaded.RemoveAll(a => a == null);

        // 添加运行时 XRGeneralSettings_iOS
        bool found = preloaded.Any(a => a != null && a == xrGeneralSettings);
        if (!found)
        {
            preloaded.Add(xrGeneralSettings);
            Debug.Log($"[BuildiOS] 已将 XRGeneralSettings_iOS 添加到 preloadedAssets (共 {preloaded.Count} 项)");
        }
        else
        {
            Debug.Log("[BuildiOS] XRGeneralSettings_iOS 已在 preloadedAssets 中");
        }

        PlayerSettings.SetPreloadedAssets(preloaded.ToArray());

        // 同时确保 XRManagerSettings_iOS 也在 preloadedAssets 中
        var xrManagerSettings = AssetDatabase.LoadAssetAtPath<Object>("Assets/XR/Settings/XRManagerSettings_iOS.asset");
        if (xrManagerSettings != null)
        {
            preloaded = PlayerSettings.GetPreloadedAssets().ToList();
            if (!preloaded.Any(a => a != null && a == xrManagerSettings))
            {
                preloaded.Add(xrManagerSettings);
                PlayerSettings.SetPreloadedAssets(preloaded.ToArray());
                Debug.Log($"[BuildiOS] 已将 XRManagerSettings_iOS 添加到 preloadedAssets");
            }
        }

        // 验证最终 preloadedAssets 内容
        var finalPreloaded = PlayerSettings.GetPreloadedAssets();
        Debug.Log($"[BuildiOS] 最终 preloadedAssets ({finalPreloaded.Length} 项):");
        for (int i = 0; i < finalPreloaded.Length; i++)
        {
            var asset = finalPreloaded[i];
            if (asset != null)
                Debug.Log($"  [{i}] {asset.name} ({asset.GetType().FullName}) path={AssetDatabase.GetAssetPath(asset)}");
            else
                Debug.Log($"  [{i}] NULL");
        }
    }
}
