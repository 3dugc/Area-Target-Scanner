#!/usr/bin/env python3
"""Build the real private AreaTargetNative framework without changing Unity artifacts.

Dependencies and build results live in --cache-dir. Xcode may request a copy into
--output-dir (normally BUILT_PRODUCTS_DIR); signing/embedding belongs to Xcode.
"""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = "5.0.0"
SOURCE_SHA256 = "b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095"
CONTRIB_SHA256 = "c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f"
SOURCES = tuple(sorted((ROOT / "native_visual_localizer/src").glob("*.cpp")))
HEADER = ROOT / "ios_scanner/AreaTargetScanner/ThirdParty/AreaTargetNative/AreaTargetNative.h"
NOTICES = HEADER.with_name("ThirdPartyNotices.md")
LICENSE_SHA256 = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
LICENSE_CHANGE_SHA256 = "b2255f81ae7162e36550daefe432c72a8506cfc1b954897dbc553ed5160ad4b8"


def license_resources():
    """Repository texts are byte-pinned to the verified official source release."""
    notices = NOTICES.read_bytes()
    resources = {"ThirdPartyNotices.md": notices}
    for label, expected in (("LICENSE", LICENSE_SHA256), ("LICENSE_CHANGE_NOTICE", LICENSE_CHANGE_SHA256)):
        begin = ("<!-- BEGIN OpenCV " + label + " -->\n```text\n").encode()
        end = ("```\n<!-- END OpenCV " + label + " -->").encode()
        if notices.count(begin) != 1 or notices.count(end) != 1:
            raise ValueError("OpenCV license markers are missing or ambiguous")
        data = notices.split(begin, 1)[1].split(end, 1)[0]
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("official OpenCV " + label + " text SHA256 mismatch")
        resources["OpenCV-" + label + ".txt"] = data
    return resources


def verify_license_resources(framework, resources):
    for name, expected in resources.items():
        path = framework / name
        if not path.is_file() or path.read_bytes() != expected:
            raise ValueError("distributed OpenCV license resource is missing or changed: " + str(path))


def run(arguments, *, log=None):
    print("+", " ".join(str(arg) for arg in arguments), flush=True)
    result = subprocess.run([str(arg) for arg in arguments], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        print(result.stdout, flush=True)
        raise RuntimeError(f"command failed ({result.returncode}); log={log}")
    return result.stdout


def digest(path):
    with Path(path).open("rb") as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
        return checksum.hexdigest()


def validate_opencv_framework(framework, platform):
    """Check cached dependency contents before it can enter an Apple framework."""
    framework = Path(framework)
    metadata = json.loads((framework / "dependency.json").read_text())
    if metadata.get("version") != VERSION:
        raise ValueError("OpenCV dependency must be pinned 5.0.0")
    for key, expected in (("platform", platform), ("architecture", "arm64"),
                          ("sourceSHA256", SOURCE_SHA256), ("contribSHA256", CONTRIB_SHA256)):
        if metadata.get(key) != expected:
            raise ValueError("OpenCV dependency " + key + " mismatch")
    version = (framework / "Headers/core/version.hpp").read_text()
    for name, number in (("MAJOR", 5), ("MINOR", 0), ("REVISION", 0)):
        if not re.search(r"^#define CV_VERSION_" + name + r"\s+" + str(number) + r"\s*$", version, re.M):
            raise ValueError("OpenCV dependency headers must be 5.0.0")
    if not (framework / "Headers/xfeatures2d.hpp").is_file() or "xfeatures2d" not in metadata.get("modules", []):
        raise ValueError("OpenCV contrib xfeatures2d/AKAZE is required")
    if metadata.get("binarySHA256") != digest(framework / "opencv2"):
        raise ValueError("OpenCV dependency binary SHA256 mismatch")
    licenses = framework / "Licenses"
    for name in ("OpenCV-LICENSE.txt", "OpenCV-Contrib-LICENSE.txt", "AKAZE-LICENSE.txt", "KAZE-LICENSE.txt"):
        if not (licenses / name).is_file():
            raise ValueError("OpenCV dependency license missing: " + name)
    actual_licenses = {str(path.relative_to(licenses)): digest(path)
                      for path in sorted(licenses.rglob("*")) if path.is_file()}
    if actual_licenses != metadata.get("licenseSHA256s"):
        raise ValueError("OpenCV dependency license SHA256 mismatch")
    return metadata


def opencv_dependency(cache, platform, jobs, framework=None):
    explicit = framework is not None
    framework = Path(framework) if explicit else cache / "dependencies" / platform / "opencv2.framework"
    if explicit and not (framework / "dependency.json").is_file():
        raise ValueError("explicit OpenCV framework is missing pinned 5 + contrib provenance")
    if not (framework / "dependency.json").is_file():
        dependency_cache = cache / "opencv5-source"
        env = os.environ.copy()
        env.update({"PLATFORM": platform, "IOS_DEPLOYMENT_TARGET": "16.0", "JOBS": str(jobs),
                    "OPENCV_DIR": str(framework.parent)})
        # Device and Simulator share pinned source extraction/download paths.
        with (cache / "opencv5-source.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run(["bash", str(ROOT / "tools/opencv5/build_ios_dependency.sh"), str(dependency_cache)],
                                    env=env, text=True)
            if result.returncode:
                raise RuntimeError("pinned OpenCV 5 Apple dependency build failed")
    metadata = validate_opencv_framework(framework, platform)
    architecture = run(["lipo", "-archs", framework / "opencv2"]).strip()
    if architecture != "arm64":
        raise ValueError("OpenCV dependency must have one arm64 slice")
    load = run(["otool", "-l", framework / "opencv2"], log=cache / (platform + "-opencv-platform.log"))
    expected = "2" if platform == "iphoneos" else "7"
    actual = set(re.findall(r"platform\s+(\d+)\b", load))
    if actual != {expected}:
        raise ValueError("OpenCV dependency Mach-O platform mismatch: " + str(actual))
    return [framework / "opencv2"], ["-F", str(framework.parent)], metadata, framework


def framework_sdk_info(platform, sdk):
    """Mirror Xcode's processed framework metadata using the selected real SDK."""
    sdk = Path(sdk)
    def load(path):
        with path.open("rb") as stream:
            return plistlib.load(stream)
    settings = load(sdk / "SDKSettings.plist")
    platform_info = load(sdk.parents[2] / "Info.plist")
    sdk_version = load(sdk / "System/Library/CoreServices/SystemVersion.plist")
    xcode_info = load(sdk.parents[5] / "Info.plist")
    xcode_version = load(sdk.parents[5] / "version.plist")
    host = load(Path("/System/Library/CoreServices/SystemVersion.plist"))
    if settings["DefaultProperties"]["PLATFORM_NAME"] != platform:
        raise ValueError("selected SDK metadata disagrees with requested platform")
    return {"CFBundleInfoDictionaryVersion": "6.0", "CFBundleDevelopmentRegion": "en",
            "BuildMachineOSBuild": host["ProductBuildVersion"],
            "DTCompiler": settings["DefaultProperties"]["DEFAULT_COMPILER"],
            "DTPlatformName": platform, "DTPlatformVersion": platform_info["Version"],
            "DTPlatformBuild": sdk_version["ProductBuildVersion"],
            "DTSDKName": settings["CanonicalName"], "DTSDKBuild": sdk_version["ProductBuildVersion"],
            "DTXcode": xcode_info["DTXcode"], "DTXcodeBuild": xcode_version["ProductBuildVersion"],
            "UIDeviceFamily": [int(family["Identifier"]) for family in
                               settings["SupportedTargets"][platform]["DeviceFamilies"]]}


def build_framework(cache, platform, jobs, opencv_framework=None):
    from verify_area_target_native import verify_framework, REQUIRED
    original = ROOT / "native_visual_localizer/include/visual_localizer.h"
    if HEADER.read_bytes() != original.read_bytes():
        raise ValueError("AreaTargetNative C header must exactly mirror native header")
    libraries, opencv_flags, metadata, dependency_framework = opencv_dependency(cache, platform, jobs, opencv_framework)
    resources = license_resources()
    metadata.update({"licenseSHA256": LICENSE_SHA256, "licenseChangeSHA256": LICENSE_CHANGE_SHA256,
                     "thirdPartyNoticesSHA256": digest(NOTICES)})
    sdk = run(["xcrun", "--sdk", platform, "--show-sdk-path"]).strip()
    compiler = run(["xcrun", "--sdk", platform, "--find", "clang++"]).strip()
    standard_info = framework_sdk_info(platform, sdk)
    target = "arm64-apple-ios16.0" + ("-simulator" if platform == "iphonesimulator" else "")
    public_headers = list(sorted((ROOT / "native_visual_localizer/include").glob("*.h")))
    private_headers = list(sorted((ROOT / "native_visual_localizer/src").glob("*.h")))
    inputs = [*SOURCES, *public_headers, *private_headers, HEADER, NOTICES, Path(__file__),
              ROOT / "tools/ios/verify_area_target_native.py", ROOT / "tools/phase0/required_combined_native_symbols.txt"]
    key = hashlib.sha256((platform + target + sdk + json.dumps(standard_info, sort_keys=True) + json.dumps(metadata, sort_keys=True) +
                         "".join(digest(path) for path in inputs)).encode()).hexdigest()[:20]
    build = cache / "frameworks" / key / platform
    framework = build / "AreaTargetNative.framework"
    if (build / "verified.json").is_file():
        verify_framework(framework, platform)
        verify_license_resources(framework, resources)
        return framework
    build.mkdir(parents=True, exist_ok=True)
    framework.mkdir(exist_ok=True)
    exports = build / "exports.txt"
    exports.write_text("".join("_" + name + "\n" for name in REQUIRED))
    objects = []
    common = [compiler, "-target", target, "-isysroot", sdk, "-std=c++17", "-O2", "-DNDEBUG",
              "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-fPIC", "-I", original.parent,
              "-I", SOURCES[0].parent, *opencv_flags]
    for source in SOURCES:
        obj = build / (source.stem + ".o")
        run([*common, "-c", source, "-o", obj], log=build / (source.stem + ".log"))
        objects.append(obj)
    run([*common, "-dynamiclib", *objects, *libraries, "-o", framework / "AreaTargetNative",
         "-Wl,-install_name,@rpath/AreaTargetNative.framework/AreaTargetNative",
         "-Wl,-exported_symbols_list," + str(exports), "-Wl,-twolevel_namespace", "-Wl,-dead_strip",
         "-framework", "Foundation", "-framework", "Accelerate", "-framework", "AVFoundation",
         "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "CoreGraphics",
         "-framework", "UIKit", "-lz", "-lsqlite3", "-lc++"], log=build / "link.log")
    (framework / "Headers").mkdir(exist_ok=True)
    (framework / "Modules").mkdir(exist_ok=True)
    shutil.copy2(HEADER, framework / "Headers/AreaTargetNative.h")
    shutil.copy2(original.with_name("area_target_runtime.h"), framework / "Headers/area_target_runtime.h")
    (framework / "Modules/module.modulemap").write_text(
        'framework module AreaTargetNative {\n  umbrella header "AreaTargetNative.h"\n  header "area_target_runtime.h"\n  export *\n}\n')
    with (framework / "Info.plist").open("wb") as stream:
        plistlib.dump({**standard_info, "CFBundleExecutable": "AreaTargetNative", "CFBundleIdentifier": "com.areatarget.native",
                      "CFBundleName": "AreaTargetNative", "CFBundlePackageType": "FMWK",
                      "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                      "MinimumOSVersion": "16.0", "CFBundleSupportedPlatforms":
                      ["iPhoneOS" if platform == "iphoneos" else "iPhoneSimulator"]}, stream, fmt=plistlib.FMT_BINARY)
    for name, data in resources.items():
        (framework / name).write_bytes(data)
    verify_license_resources(framework, resources)
    shutil.copytree(dependency_framework / "Licenses", framework / "Licenses", dirs_exist_ok=True)
    metadata["opencvBinarySHA256"] = metadata.pop("binarySHA256")
    metadata["binarySHA256"] = digest(framework / "AreaTargetNative")
    metadata["runtimeApiVersion"] = 2
    metadata["runtimeSourceSHA256s"] = {str(path.relative_to(ROOT)): digest(path) for path in
                                       [*SOURCES, *public_headers, *private_headers]}
    (framework / "dependency.json").write_text(json.dumps(metadata, indent=2, sort_keys=True))
    verification = verify_framework(framework, platform)
    (build / "verified.json").write_text(json.dumps(verification, indent=2))
    return framework


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("iphoneos", "iphonesimulator"),
                        default=os.environ.get("PLATFORM_NAME", "iphoneos"))
    parser.add_argument("--cache-dir", type=Path, default=Path(os.environ.get("AREA_TARGET_NATIVE_CACHE", ROOT / "build/opencv5-unification/native-apple")))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--opencv-framework", type=Path, default=os.environ.get("AREA_TARGET_OPENCV_FRAMEWORK"),
                        help="explicit pinned OpenCV 5 + contrib framework for the requested platform")
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 2))
    arguments = parser.parse_args()
    arguments.cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        with (arguments.cache_dir / ("build-" + arguments.platform + ".lock")).open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            framework = build_framework(arguments.cache_dir, arguments.platform, arguments.jobs, arguments.opencv_framework)
        if arguments.output_dir:
            arguments.output_dir.mkdir(parents=True, exist_ok=True)
            destination = arguments.output_dir / framework.name
            if destination.resolve() != framework.resolve():
                if destination.exists():
                    shutil.rmtree(destination)
                shutil.copytree(framework, destination)
            framework = destination
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"FAIL AreaTargetNative build: {error}\n")
    print(json.dumps({"framework": str(framework.resolve()), "platform": arguments.platform}, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
