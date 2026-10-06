#!/usr/bin/env python3
import gzip
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "unity_plugin/AreaTargetPlugin"
DIST = ROOT / "dist"
IOS_PLUGIN_SOURCE = ROOT / "unity_project/Assets/Plugins/iOS/libvisual_localizer.a"
IOS_OPENCV_FRAMEWORK_SOURCE = ROOT / "native_visual_localizer/opencv_ios/5.0.0/opencv2.framework"
EXCLUDED_NAMES = {
    "Tests",
    "Tests.meta",
    "PropertyTests",
    "PropertyTests.meta",
    "__pycache__",
}
EXCLUDED_SUFFIXES = {
    ".tgz",
    ".tgz.meta",
    ".unitypackage",
    ".unitypackage.meta",
    ".bak2",
    ".bak2.meta",
    ".data1_bak",
    ".data1_bak.meta",
}


def ignored(_directory, names):
    return {
        name
        for name in names
        if name in EXCLUDED_NAMES
        or any(name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES)
    }


def validate_opencv_framework(framework):
    """Reject a stale framework before combining it with the rebuilt wrapper."""
    header = Path(framework) / "Headers/core/version.hpp"
    if not header.is_file():
        raise ValueError(f"missing OpenCV 5.0.0 version header: {header}")
    text = header.read_text()
    parts = [re.search(rf"^\s*#define\s+CV_VERSION_{name}\s+(\d+)\s*$", text, re.M)
             for name in ("MAJOR", "MINOR", "REVISION")]
    version = ".".join(part.group(1) for part in parts) if all(parts) else "unknown"
    if version != "5.0.0":
        raise ValueError(f"expected OpenCV 5.0.0 framework, found {version}: {framework}")
    if not (Path(framework) / "Headers/xfeatures2d.hpp").is_file():
        raise ValueError(f"OpenCV 5 framework needs contrib xfeatures2d for AKAZE: {framework}")
    provenance = Path(framework) / "dependency.json"
    if not provenance.is_file():
        raise ValueError(f"OpenCV framework lacks verified dependency.json: {framework}")
    metadata = json.loads(provenance.read_text())
    expected = {
        "version": "5.0.0", "platform": "iphoneos", "architecture": "arm64",
        "sourceSHA256": "b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095",
        "contribSHA256": "c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f",
    }
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError(f"unexpected OpenCV framework dependency identity: {framework}")
    if "xfeatures2d" not in metadata.get("modules", []):
        raise ValueError(f"OpenCV framework lacks AKAZE contrib module: {framework}")
    binary = Path(framework) / "opencv2"
    if not binary.is_file() or hashlib.sha256(binary.read_bytes()).hexdigest() != metadata.get("binarySHA256"):
        raise ValueError(f"OpenCV framework binary SHA256 mismatch: {framework}")


def add_tree(archive, root):
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root.parent)
        info = archive.gettarinfo(str(path), arcname=str(relative))
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        if path.is_file():
            with path.open("rb") as stream:
                archive.addfile(info, stream)
        else:
            archive.addfile(info)


def main():
    metadata = json.loads((SOURCE / "package.json").read_text())
    version = metadata["version"]
    DIST.mkdir(exist_ok=True)
    output = DIST / f"com.areatarget.tracking-{version}.tgz"
    with tempfile.TemporaryDirectory(prefix="area-target-upm-") as temp:
        package = Path(temp) / "package"
        shutil.copytree(SOURCE, package, ignore=ignored)
        for platform, filename in (("iOS", "libvisual_localizer.a"), ("macOS", "libvisual_localizer.dylib")):
            source = IOS_PLUGIN_SOURCE if platform == "iOS" else ROOT / "unity_project/Assets/Plugins" / platform / filename
            if not source.is_file() or source.stat().st_size == 0:
                raise SystemExit(f"missing native artifact: {source}")
            target = package / "Runtime/Plugins" / platform / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            meta = source.with_suffix(source.suffix + ".meta")
            if meta.is_file():
                shutil.copy2(meta, target.with_suffix(target.suffix + ".meta"))

        if not IOS_OPENCV_FRAMEWORK_SOURCE.is_dir():
            raise SystemExit(f"missing iOS OpenCV framework: {IOS_OPENCV_FRAMEWORK_SOURCE}")
        validate_opencv_framework(IOS_OPENCV_FRAMEWORK_SOURCE)
        shutil.copytree(
            IOS_OPENCV_FRAMEWORK_SOURCE,
            package / "Runtime/Plugins/iOS/opencv2.framework",
            symlinks=True,
        )
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    add_tree(archive, package)
    print(output)


if __name__ == "__main__":
    main()
