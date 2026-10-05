import hashlib
import importlib.util
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/phase0/build_upm_package.py"

REQUIRED = {
    "package/package.json",
    "package/Runtime/AlignmentTransformCalculator.cs",
    "package/Runtime/ExtendedDebugInfo.cs",
    "package/Runtime/GLBMeshLoader.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
    "package/Runtime/Plugins/macOS/libvisual_localizer.dylib",
    "package/ThirdPartyLicenses/OpenCV5/OpenCV-LICENSE.txt",
    "package/ThirdPartyLicenses/OpenCV5/OpenCV-Contrib-LICENSE.txt",
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


def load_builder():
    spec = importlib.util.spec_from_file_location("upm_builder", BUILDER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_opencv4_framework_cannot_be_packaged_with_upgrade(tmp_path):
    framework = tmp_path / "opencv2.framework"
    header = framework / "Headers/core/version.hpp"
    header.parent.mkdir(parents=True)
    header.write_text("#define CV_VERSION_MAJOR 4\n#define CV_VERSION_MINOR 10\n#define CV_VERSION_REVISION 0\n")
    with pytest.raises(ValueError, match="5.0.0"):
        load_builder().validate_opencv_framework(framework)


def test_pinned_opencv5_framework_is_accepted(tmp_path):
    framework = tmp_path / "opencv2.framework"
    header = framework / "Headers/core/version.hpp"
    header.parent.mkdir(parents=True)
    header.write_text("#define CV_VERSION_MAJOR 5\n#define CV_VERSION_MINOR 0\n#define CV_VERSION_REVISION 0\n")
    (framework / "Headers/xfeatures2d.hpp").write_text("class AKAZE;\n")
    (framework / "opencv2").write_bytes(b"verified fixture binary")
    (framework / "dependency.json").write_text(json.dumps({
        "version": "5.0.0", "architecture": "arm64", "platform": "iphoneos",
        "sourceSHA256": "b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095",
        "contribSHA256": "c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f",
        "modules": ["core", "imgproc", "features", "geometry", "xfeatures2d"],
        "binarySHA256": hashlib.sha256((framework / "opencv2").read_bytes()).hexdigest(),
    }))
    load_builder().validate_opencv_framework(framework)


def test_tampered_opencv_framework_binary_is_rejected(tmp_path):
    test_pinned_opencv5_framework_is_accepted(tmp_path)
    framework = tmp_path / "opencv2.framework"
    (framework / "opencv2").write_bytes(b"stale binary")
    with pytest.raises(ValueError, match="SHA256"):
        load_builder().validate_opencv_framework(framework)


def test_opencv5_core_only_framework_is_rejected(tmp_path):
    framework = tmp_path / "opencv2.framework"
    header = framework / "Headers/core/version.hpp"
    header.parent.mkdir(parents=True)
    header.write_text("#define CV_VERSION_MAJOR 5\n#define CV_VERSION_MINOR 0\n#define CV_VERSION_REVISION 0\n")
    with pytest.raises(ValueError, match="AKAZE"):
        load_builder().validate_opencv_framework(framework)


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
