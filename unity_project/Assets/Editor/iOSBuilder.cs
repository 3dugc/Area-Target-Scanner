using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public class iOSBuilder
{
    [MenuItem("Build/Build iOS")]
    public static void BuildiOS()
    {
        string[] scenes = new string[]
        {
            "Assets/Scenes/SLAMTestScene.unity",
            "Assets/Scenes/DownloadTestScene.unity",
            "Assets/Scenes/TestScene.unity",
            "Assets/Scenes/ARTestScene.unity"
        };

        BuildPlayerOptions buildPlayerOptions = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = "../build/ios_xcode",
            target = BuildTarget.iOS,
            options = BuildOptions.None
        };

        BuildReport report = BuildPipeline.BuildPlayer(buildPlayerOptions);
        BuildSummary summary = report.summary;

        if (summary.result == BuildResult.Succeeded)
        {
            Debug.Log($"[iOSBuilder] 构建成功! 大小: {summary.totalSize} bytes, 耗时: {summary.totalTime}");
            EditorApplication.Exit(0);
        }
        else
        {
            Debug.LogError($"[iOSBuilder] 构建失败: {summary.result}");
            foreach (var step in report.steps)
            {
                foreach (var msg in step.messages)
                {
                    if (msg.type == LogType.Error || msg.type == LogType.Warning)
                        Debug.LogError($"  {msg.type}: {msg.content}");
                }
            }
            EditorApplication.Exit(1);
        }
    }
}
