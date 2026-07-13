#!/usr/bin/env python3
import gzip
import json
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "unity_plugin/AreaTargetPlugin"
DIST = ROOT / "dist"
IOS_PLUGIN_SOURCE = ROOT / "unity_project/Assets/Plugins/iOS/libvisual_localizer.a"
IOS_OPENCV_FRAMEWORK_SOURCE = ROOT / "native_visual_localizer/opencv_ios/opencv2.framework"
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
