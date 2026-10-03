import hashlib
import json
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/phase0/build_upm_package.py"

REQUIRED = {
    "package/package.json",
    "package/Runtime/AlignmentTransformCalculator.cs",
    "package/Runtime/ExtendedDebugInfo.cs",
    "package/Runtime/GLBMeshLoader.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
    "package/Runtime/Plugins/macOS/libvisual_localizer.dylib",
}
REQUIRED_IOS = {
    "package/Editor/iOSPostProcess.cs",
    "package/Editor/AreaTargetIosXrBootstrap.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
}
OPENCV_FRAMEWORK_PREFIX = "package/Runtime/Plugins/iOS/opencv2.framework/"
SQLITE_DEPENDENCY = "1.3.2"
ARKIT_DEPENDENCY = "6.0.0"
VALIDATE_UNITY_PACKAGES = (
    ROOT / "tools/phase0/validate_unity_package.sh",
    ROOT / "tools/phase1/validate_ios_upm_build.sh",
)


def build():
    subprocess.run([sys.executable, str(BUILDER)], cwd=ROOT, check=True)
    return hashlib.sha256(output_path().read_bytes()).hexdigest()


def output_path():
    metadata = json.loads((ROOT / "unity_plugin/AreaTargetPlugin/package.json").read_text())
    return ROOT / f"dist/com.areatarget.tracking-{metadata['version']}.tgz"


def test_package_content_and_reproducibility():
    first = build()
    second = build()
    assert first == second
    with tarfile.open(output_path(), "r:gz") as archive:
        names = set(archive.getnames())
    assert REQUIRED <= names
    assert not any("/Tests" in name or "/PropertyTests" in name for name in names)
    assert not any(name.endswith((".unitypackage", ".tgz", ".bak2")) for name in names)


def test_package_contains_self_contained_ios_linking_dependencies():
    build()
    with tarfile.open(output_path(), "r:gz") as archive:
        names = set(archive.getnames())
        metadata = json.load(archive.extractfile("package/package.json"))

    assert REQUIRED_IOS <= names
    assert any(name.startswith(OPENCV_FRAMEWORK_PREFIX) for name in names)
    assert metadata["dependencies"]["com.gilzoide.sqlite-net"] == SQLITE_DEPENDENCY
    assert metadata["dependencies"]["com.unity.xr.arkit"] == ARKIT_DEPENDENCY


def test_clean_install_does_not_inject_sqlite_dependency_into_temporary_manifest():
    for validation_script_path in VALIDATE_UNITY_PACKAGES:
        validation_script = validation_script_path.read_text()
        assert 'dependencies["com.gilzoide.sqlite-net"]' not in validation_script
        assert '"scopedRegistries"' in validation_script
        assert "https://package.openupm.com" in validation_script


def test_clean_ios_validation_bootstraps_official_arkit_loader_before_export():
    validation_script = (ROOT / "tools/phase1/validate_ios_upm_build.sh").read_text()

    assert "AreaTargetIosXrBootstrap.Configure" in validation_script
    assert "libUnityARKit.a" in validation_script
    assert validation_script.index("AreaTargetIosXrBootstrap.Configure") < validation_script.index(
        "BuildiOS.BuildDevelopment"
    )


def test_ios_build_entry_assembly_references_package_editor_bootstrap():
    build_entry_assembly = json.loads(
        (ROOT / "unity_project/Assets/Editor/Editor.asmdef").read_text()
    )

    assert "AreaTargetPlugin.Editor" in build_entry_assembly["references"]
