using UnityEditor;
using UnityEngine;
using System.IO;
using System.Collections.Generic;

/// <summary>
/// Exports AreaTargetPlugin as a .unitypackage with all runtime dependencies.
/// Tests are excluded — they require com.unity.test-framework and FsCheck
/// which are dev-only dependencies not needed by end users.
/// </summary>
public static class PackageExporter
{
    [System.Serializable]
    private class PackageManifest
    {
        public string version;
    }

    private static string ReadPackageVersion()
    {
        const string manifestPath = "Packages/com.areatarget.tracking/package.json";
        var json = File.ReadAllText(Path.GetFullPath(manifestPath));
        var manifest = JsonUtility.FromJson<PackageManifest>(json);
        if (manifest == null || string.IsNullOrWhiteSpace(manifest.version))
            throw new InvalidDataException($"Missing version in {manifestPath}");
        return manifest.version;
    }

    [MenuItem("Tools/Export AreaTargetPlugin Package")]
    public static void Export()
    {
        var version = ReadPackageVersion();
        var outputPath = Path.GetFullPath(
            Path.Combine(Application.dataPath,
                $"../../unity_plugin/AreaTargetPlugin/AreaTargetPlugin-{version}.unitypackage")
        );

        var assetPaths = new List<string>();

        // 1. Package source code (Runtime + Editor only, no Tests)
        CollectAssets("Packages/com.areatarget.tracking/Runtime", assetPaths);
        CollectAssets("Packages/com.areatarget.tracking/Editor", assetPaths);

        // Package root metadata files
        string[] rootFiles = {
            "package.json", "CHANGELOG.md", "LICENSE.md", "README.md",
        };
        foreach (var f in rootFiles)
        {
            var p = "Packages/com.areatarget.tracking/" + f;
            if (AssetDatabase.LoadAssetAtPath<Object>(p) != null)
                assetPaths.Add(p);
        }

        // 2. Native plugins (dylib/so/dll) and managed DLLs
        CollectAssets("Assets/Plugins", assetPaths);

        // 3. link.xml (prevents IL2CPP from stripping SQLite assemblies)
        if (AssetDatabase.LoadAssetAtPath<Object>("Assets/link.xml") != null)
            assetPaths.Add("Assets/link.xml");

        if (assetPaths.Count == 0)
        {
            Debug.LogError("[PackageExporter] No assets found to export.");
            if (Application.isBatchMode) EditorApplication.Exit(1);
            return;
        }

        Debug.Log($"[PackageExporter] Exporting {assetPaths.Count} assets to {outputPath}");
        AssetDatabase.ExportPackage(
            assetPaths.ToArray(),
            outputPath,
            ExportPackageOptions.Recurse
        );
        Debug.Log($"[PackageExporter] Export complete: {outputPath}");

        if (Application.isBatchMode)
            EditorApplication.Exit(0);
    }

    static void CollectAssets(string folder, List<string> results)
    {
        var guids = AssetDatabase.FindAssets("", new[] { folder });
        foreach (var guid in guids)
        {
            var path = AssetDatabase.GUIDToAssetPath(guid);
            if (!string.IsNullOrEmpty(path))
                results.Add(path);
        }
    }
}
