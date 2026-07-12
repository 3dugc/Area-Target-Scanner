using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 一次性工具：为所有场景中缺失 CanvasRenderer 的 UI 组件（Text/Image）自动补上。
/// 运行后可删除此脚本。
/// </summary>
public class FixMissingCanvasRenderers
{
    [MenuItem("Tools/Fix Missing CanvasRenderers")]
    public static void Fix()
    {
        string[] sceneGuids = AssetDatabase.FindAssets("t:Scene", new[] { "Assets/Scenes" });
        int totalFixed = 0;

        foreach (string guid in sceneGuids)
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            var scene = EditorSceneManager.OpenScene(path, OpenSceneMode.Single);
            int fixed_ = 0;

            foreach (var graphic in Object.FindObjectsByType<Graphic>(FindObjectsSortMode.None))
            {
                if (graphic.GetComponent<CanvasRenderer>() == null)
                {
                    graphic.gameObject.AddComponent<CanvasRenderer>();
                    fixed_++;
                }
            }

            if (fixed_ > 0)
            {
                EditorSceneManager.SaveScene(scene);
                Debug.Log($"[FixCanvasRenderer] {path}: 修复了 {fixed_} 个组件");
                totalFixed += fixed_;
            }
        }

        Debug.Log($"[FixCanvasRenderer] 完成，共修复 {totalFixed} 个缺失的 CanvasRenderer");
    }
}
