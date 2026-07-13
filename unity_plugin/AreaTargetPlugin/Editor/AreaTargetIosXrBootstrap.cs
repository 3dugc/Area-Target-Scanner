using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.XR.Management;
using UnityEditor.XR.Management.Metadata;
using UnityEngine;
using UnityEngine.XR.Management;
using PackageInfo = UnityEditor.PackageManager.PackageInfo;

namespace AreaTargetPlugin.Editor
{
    /// <summary>
    /// Configures the official Apple ARKit XR loader for an iOS Unity project.
    /// Run this once in its own Unity invocation before an iOS export so Unity
    /// can reload assemblies with the ARKit provider compile define enabled.
    /// </summary>
    public static class AreaTargetIosXrBootstrap
    {
        private const string ArKitPackageName = "com.unity.xr.arkit";
        private const string ArKitLoaderTypeName = "UnityEngine.XR.ARKit.ARKitLoader";
        private const string ArKitLoaderDefine = "UNITY_XR_ARKIT_LOADER_ENABLED";
        private const string LoaderSettingsKey = "com.unity.xr.management.loader_settings";
        private const string DefaultSettingsPath = "Assets/XR/XRGeneralSettingsPerBuildTarget.asset";

        [MenuItem("Area Target/Configure iOS ARKit")]
        public static void Configure()
        {
            EnsureArKitPackageIsInstalled();

            XRGeneralSettingsPerBuildTarget settings = GetOrCreateSettings();
            if (!settings.HasManagerSettingsForBuildTarget(BuildTargetGroup.iOS))
                settings.CreateDefaultManagerSettingsForBuildTarget(BuildTargetGroup.iOS);

            XRManagerSettings manager = settings.ManagerSettingsForBuildTarget(BuildTargetGroup.iOS);
            if (manager == null)
                throw new BuildFailedException("Area Target could not create iOS XR manager settings.");

            if (!XRPackageMetadataStore.IsLoaderAssigned(ArKitLoaderTypeName, BuildTargetGroup.iOS)
                && !XRPackageMetadataStore.AssignLoader(manager, ArKitLoaderTypeName, BuildTargetGroup.iOS))
            {
                throw new BuildFailedException(
                    "Area Target could not assign the official ARKitLoader to iOS XR Plug-in Management.");
            }

            EnsureArKitLoaderDefine();
            EditorUtility.SetDirty(settings);
            EditorUtility.SetDirty(manager);
            AssetDatabase.SaveAssets();

            Debug.Log(
                "[AreaTargetPlugin] Configured the iOS ARKitLoader. "
                + "Exit this Unity invocation before building so the ARKit provider is compiled into the app.");
        }

        /// <summary>
        /// Verifies configuration that must already exist before the build
        /// invocation starts. This deliberately does not mutate settings: a
        /// define added at this point is too late for Unity's ARKit build code.
        /// </summary>
        public static void EnsureConfiguredForBuild()
        {
            EnsureArKitPackageIsInstalled();

            if (!XRPackageMetadataStore.IsLoaderAssigned(ArKitLoaderTypeName, BuildTargetGroup.iOS))
            {
                throw new BuildFailedException(
                    "iOS ARKitLoader is not configured. Run AreaTargetIosXrBootstrap.Configure "
                    + "in a separate Unity invocation, then build again.");
            }

            string defines = PlayerSettings.GetScriptingDefineSymbols(
                NamedBuildTarget.FromBuildTargetGroup(BuildTargetGroup.iOS));
            if (!defines.Split(';').Contains(ArKitLoaderDefine))
            {
                throw new BuildFailedException(
                    "UNITY_XR_ARKIT_LOADER_ENABLED is missing. Run AreaTargetIosXrBootstrap.Configure "
                    + "and restart the Unity build invocation before exporting iOS.");
            }
        }

        private static XRGeneralSettingsPerBuildTarget GetOrCreateSettings()
        {
            if (EditorBuildSettings.TryGetConfigObject(
                LoaderSettingsKey,
                out XRGeneralSettingsPerBuildTarget existingSettings)
                && existingSettings != null)
            {
                return existingSettings;
            }

            XRGeneralSettingsPerBuildTarget settings = FindExistingSettingsAsset();
            if (settings == null)
            {
                EnsureFolder("Assets/XR");
                settings = ScriptableObject.CreateInstance<XRGeneralSettingsPerBuildTarget>();
                AssetDatabase.CreateAsset(settings, DefaultSettingsPath);
            }

            EditorBuildSettings.AddConfigObject(LoaderSettingsKey, settings, true);
            return settings;
        }

        private static XRGeneralSettingsPerBuildTarget FindExistingSettingsAsset()
        {
            foreach (string guid in AssetDatabase.FindAssets("t:XRGeneralSettingsPerBuildTarget"))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (!path.StartsWith("Assets/", StringComparison.Ordinal))
                    continue;

                XRGeneralSettingsPerBuildTarget settings =
                    AssetDatabase.LoadAssetAtPath<XRGeneralSettingsPerBuildTarget>(path);
                if (settings != null)
                    return settings;
            }

            return null;
        }

        private static void EnsureArKitPackageIsInstalled()
        {
            bool installed = PackageInfo.GetAllRegisteredPackages()
                .Any(package => package.name == ArKitPackageName);
            if (!installed)
            {
                throw new BuildFailedException(
                    "Apple ARKit XR Plug-in is missing. Install the package dependency "
                    + "com.unity.xr.arkit before configuring an iOS Area Target build.");
            }
        }

        private static void EnsureArKitLoaderDefine()
        {
            NamedBuildTarget iOS = NamedBuildTarget.FromBuildTargetGroup(BuildTargetGroup.iOS);
            string[] defines = PlayerSettings.GetScriptingDefineSymbols(iOS)
                .Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            if (defines.Contains(ArKitLoaderDefine))
                return;

            PlayerSettings.SetScriptingDefineSymbols(
                iOS,
                string.Join(";", defines.Concat(new[] { ArKitLoaderDefine })));
        }

        private static void EnsureFolder(string path)
        {
            if (AssetDatabase.IsValidFolder(path))
                return;

            string parent = Path.GetDirectoryName(path)?.Replace('\\', '/');
            string name = Path.GetFileName(path);
            if (string.IsNullOrEmpty(parent) || string.IsNullOrEmpty(name))
                throw new BuildFailedException("Invalid XR settings folder: " + path);

            EnsureFolder(parent);
            AssetDatabase.CreateFolder(parent, name);
        }
    }
}
