#!/usr/bin/env python3
"""Verify a private, real AreaTargetNative Apple framework. No repository mutation."""
import argparse
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = tuple((ROOT / "tools/phase0/required_native_symbols.txt").read_text().split())

def run(*args):
    try:
        return subprocess.check_output([str(value) for value in args], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        raise ValueError(str(error) + "\n" + error.output) from error

def verify_framework(framework, platform):
    framework = Path(framework)
    binary = framework / "AreaTargetNative"
    if (framework / "Resources").exists():
        raise ValueError("private iOS framework resources must use a flat bundle layout")
    if not binary.is_file():
        raise ValueError(f"missing real native framework binary: {binary}")
    if not (framework / "Headers/AreaTargetNative.h").is_file():
        raise ValueError("framework C header is missing")
    if not (framework / "Modules/module.modulemap").is_file():
        raise ValueError("framework module map is missing")
    if (framework / "Headers/AreaTargetNative.h").read_bytes() != (ROOT / "native_visual_localizer/include/visual_localizer.h").read_bytes():
        raise ValueError("framework header does not match native C ABI")
    with (framework / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleExecutable") != "AreaTargetNative":
        raise ValueError("unexpected framework executable")
    expected_info = {"CFBundleInfoDictionaryVersion": "6.0", "CFBundlePackageType": "FMWK",
                     "CFBundleIdentifier": "com.areatarget.native", "MinimumOSVersion": "16.0",
                     "DTPlatformName": platform, "UIDeviceFamily": [1, 2],
                     "CFBundleSupportedPlatforms": ["iPhoneOS" if platform == "iphoneos" else "iPhoneSimulator"]}
    for key, value in expected_info.items():
        if info.get(key) != value:
            raise ValueError("framework Info.plist standard/platform field is missing or wrong: " + key)
    version = info.get("DTPlatformVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        raise ValueError("framework Info.plist SDK platform version is invalid")
    if info.get("DTSDKName") != platform + version:
        raise ValueError("framework Info.plist SDK name disagrees with platform/version")
    for key in ("DTSDKBuild", "DTPlatformBuild", "DTXcode", "DTXcodeBuild", "DTCompiler", "BuildMachineOSBuild"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError("framework Info.plist SDK/toolchain field is missing: " + key)
    if info["DTPlatformBuild"] != info["DTSDKBuild"]:
        raise ValueError("framework Info.plist SDK/platform builds disagree")
    from build_area_target_native import VERSION, SOURCE_SHA256, CONTRIB_SHA256, digest, license_resources, verify_license_resources
    metadata = json.loads((framework / "dependency.json").read_text())
    for key, expected in (("version", VERSION), ("sourceSHA256", SOURCE_SHA256),
                          ("contribSHA256", CONTRIB_SHA256), ("platform", platform), ("architecture", "arm64")):
        if metadata.get(key) != expected:
            raise ValueError("framework OpenCV 5 + contrib provenance mismatch: " + key)
    if "xfeatures2d" not in metadata.get("modules", []):
        raise ValueError("framework provenance lacks contrib AKAZE")
    if metadata.get("binarySHA256") != digest(binary):
        raise ValueError("framework binary SHA256 mismatch (verify producer artifact before signing)")
    verify_license_resources(framework, license_resources())
    licenses = framework / "Licenses"
    actual_licenses = {str(path.relative_to(licenses)): digest(path)
                      for path in sorted(licenses.rglob("*")) if path.is_file()}
    if not actual_licenses or actual_licenses != metadata.get("licenseSHA256s"):
        raise ValueError("framework dependency license SHA256 mismatch")
    exports = set(run("nm", "-gjU", binary).split())
    expected = {"_" + name for name in REQUIRED}
    if exports != expected:
        raise ValueError(f"C ABI exports differ: missing={sorted(expected-exports)}, unexpected={sorted(exports-expected)}")
    imports = run("nm", "-u", binary) + run("xcrun", "dyld_info", "-imports", binary)
    if re.search(r"__Z[^\s]*2cv[^\s]*", imports):
        raise ValueError("framework imports OpenCV C++ symbols instead of binding its private implementation")
    load = run("otool", "-l", binary)
    expected_platform = {"iphoneos": "2", "iphonesimulator": "7"}[platform]
    if not re.search(r"platform\s+" + expected_platform + r"\b", load):
        raise ValueError(f"binary is not built for {platform}")
    if not re.search(r"minos\s+16\.0(?:\.0)?\b", load):
        raise ValueError("framework minimum iOS target must be 16.0")
    if not re.search(r"sdk\s+" + re.escape(version) + r"(?:\.0)?(?:\s|$)", load):
        raise ValueError("framework Info.plist SDK version disagrees with Mach-O build metadata")
    if "TWOLEVEL" not in run("otool", "-hv", binary):
        raise ValueError("two-level namespace is required for private OpenCV isolation")
    arch = run("lipo", "-archs", binary).strip()
    if arch != "arm64":
        raise ValueError(f"expected arm64 native slice, got {arch}")
    return {"framework": str(framework.resolve()), "platform": platform, "architecture": arch,
            "exportedCFunctions": len(expected), "privateOpenCV": True}

def verify_composite_link(framework, library, work, sdk_directory=None):
    """Link both complete C APIs in one device image; private cv stays in its dylib."""
    framework, library, work = Path(framework), Path(library), Path(work)
    if not library.is_file():
        raise ValueError(f"Immersal composite-link library is missing: {library}")
    work.mkdir(parents=True, exist_ok=True)
    header = (Path(sdk_directory) if sdk_directory else ROOT / "ios_scanner/AreaTargetScanner/ThirdParty/Immersal") / "ImmersalNative.h"
    names = list(REQUIRED) + ["icvLoadMap", "icvFreeMap", "icvPointsGetCount", "icvLocalize"]
    code = '#include "AreaTargetNative.h"\n#include "ImmersalNative.h"\n'
    code += '_Static_assert(sizeof(VLResult)==76,"VLResult ABI");\n_Static_assert(sizeof(VLDebugInfo)==48,"VLDebugInfo ABI");\n'
    code += 'const void *api[]={' + ','.join('(const void *)&' + name for name in names) + '};\n'
    code += 'int main(void) { return api[0] == 0; }\n'
    source = work / "composite_link.c"
    source.write_text(code)
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").strip()
    output = work / "composite_link"
    command = ["xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios16.0",
               "-isysroot", sdk, "-I", str(framework / "Headers"), "-I", str(header.parent),
               str(source), str(library), "-F", str(framework.parent), "-framework", "AreaTargetNative",
               "-lc++", "-lz", "-lsqlite3", "-framework", "Foundation", "-framework", "Accelerate",
               "-framework", "AVFoundation", "-framework", "CoreMedia", "-framework", "CoreVideo",
               "-framework", "CoreGraphics", "-framework", "UIKit", "-framework", "Security",
               "-Wl,-rpath,@executable_path/Frameworks", "-o", str(output)]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (work / "composite_link.log").write_text(result.stdout)
    (work / "composite_link.command.json").write_text(json.dumps(command, indent=2))
    if result.returncode:
        raise ValueError(f"same-device-image Immersal/native link failed: {work / 'composite_link.log'}\n{result.stdout}")
    imports = run("xcrun", "dyld_info", "-imports", output)
    (work / "composite_imports.log").write_text(imports)
    if "AreaTargetNative" not in run("otool", "-L", output):
        raise ValueError("composite image is missing its private AreaTargetNative dependency")
    for name in REQUIRED:
        if "_" + name not in imports:
            raise ValueError(f"composite image did not bind the real {name} API")
    sdk_exports = set(run("nm", "-gjU", output).split())
    for name in names[len(REQUIRED):]:
        if "_" + name not in sdk_exports:
            raise ValueError(f"composite image did not link Immersal {name}")
    return {"compositeLink": str(output), "immersalLibrary": str(library.resolve()),
            "immersalLibrarySHA256": __import__("hashlib").sha256(library.read_bytes()).hexdigest(),
            "immersalHeaderSHA256": __import__("hashlib").sha256(header.read_bytes()).hexdigest(),
            "referencedNativeFunctions": len(REQUIRED), "referencedImmersalFunctions": len(names) - len(REQUIRED)}


def verify_simulator_smoke(framework, fixture, simulator, work):
    """Exercise real private C ABI ORB, forced AKAZE and blank LOST paths."""
    framework, fixture, work = Path(framework).resolve(), Path(fixture).resolve(), Path(work).resolve()
    metadata = json.loads((fixture / "fixture.json").read_text())
    if metadata.get("producerOpenCVVersion") != "5.0.0":
        raise ValueError("Simulator fixture must be produced by OpenCV 5.0.0")
    work.mkdir(parents=True, exist_ok=True)
    source = work / "native_fixture_smoke.cpp"
    source.write_text(r'''#include "AreaTargetNative.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
static_assert(sizeof(VLResult)==76,"VLResult ABI");
static_assert(sizeof(VLDebugInfo)==48,"debug ABI");
int main(int argc,char **argv) {
 if(argc!=3)return 10;
 const bool fallback=std::string(argv[2])=="akaze";
 std::ifstream in(argv[1],std::ios::binary);int count=0,len=32;
 in.read(reinterpret_cast<char*>(&count),sizeof(count));
 if(fallback)in.read(reinterpret_cast<char*>(&len),sizeof(len));
 if(count<100||count>50000||len!=(fallback?61:32))return 11;
 std::vector<unsigned char> gray(640*480),desc(count*len),ambiguous(count*32,0);
 std::vector<float> pts3(count*3),pts2(count*2);
 in.read(reinterpret_cast<char*>(gray.data()),gray.size());
 in.read(reinterpret_cast<char*>(desc.data()),desc.size());
 in.read(reinterpret_cast<char*>(pts3.data()),pts3.size()*sizeof(float));
 in.read(reinterpret_cast<char*>(pts2.data()),pts2.size()*sizeof(float));
 if(!in)return 12;
 VLHandle h=vl_create();if(!h)return 13;
 const unsigned char word[32]={};
 if(fallback){if(!vl_add_vocabulary_word(h,0,word,32,1))return 14;}
 else for(int i=0;i<count;++i)if(!vl_add_vocabulary_word(h,i,desc.data()+32*i,32,1))return 14;
 const float pose[16]={1,0,0,-.15f,0,1,0,.23f,0,0,1,-.34f,0,0,0,1};
 if(!vl_add_keyframe(h,7,pose,fallback?ambiguous.data():desc.data(),count,pts3.data(),pts2.data()))return 15;
 if(fallback&&!vl_add_keyframe_akaze(h,7,desc.data(),count,len,pts3.data(),pts2.data()))return 15;
 if(!vl_build_index(h))return 15;
 VLResult r;vl_process_frame_out(h,gray.data(),640,480,500,510,320,240,0,nullptr,&r);
 VLDebugInfo d;vl_get_debug_info(h,&d);
 const float expected[16]={1,0,0,.15f,0,1,0,-.23f,0,0,1,.34f,0,0,0,1};float error=0;
 for(int i=0;i<16;++i){if(!std::isfinite(r.pose[i]))return 16;error=std::max(error,std::fabs(r.pose[i]-expected[i]));}
 std::cout<<argv[2]<<" knownPose state="<<r.state<<" inliers="<<r.matched_features<<" maxPoseError="<<error<<" akazeTriggered="<<d.akaze_triggered<<"\n";
 if(r.state!=1||r.matched_features<100||error>.01f||d.akaze_triggered!=(fallback?1:0))return 16;
 if(fallback&&d.akaze_best_inliers!=r.matched_features)return 16;
 std::fill(gray.begin(),gray.end(),0);
 vl_reset(h);vl_process_frame_out(h,gray.data(),640,480,500,510,320,240,0,nullptr,&r);
 if(r.state!=2||r.confidence!=0||r.matched_features!=0)return 17;
 vl_destroy(h);std::cout<<"PASS real OpenCV known-pose and blank-frame C ABI smoke\n";return 0;
}
''')
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").strip()
    output = work / "native_fixture_smoke"
    command = ["xcrun", "--sdk", "iphonesimulator", "clang++", "-std=c++17", "-O2",
               "-target", "arm64-apple-ios16.0-simulator", "-isysroot", sdk,
               "-I", str(framework / "Headers"), str(source), "-F", str(framework.parent),
               "-framework", "AreaTargetNative", "-Wl,-rpath," + str(framework.parent), "-o", str(output)]
    run(*command)
    (work / "native_smoke.command.json").write_text(json.dumps(command, indent=2))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", output)
    results = []
    for mode, filename in (("orb", "fixture.bin"), ("akaze", "fixture-akaze.bin")):
        result = run("xcrun", "simctl", "spawn", simulator, output, fixture / filename, mode)
        (work / (mode + "-native_smoke.log")).write_text(result)
        results.append(result.strip())
    return {"nativeSmoke": str(output), "simulator": simulator, "results": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", required=True, type=Path)
    parser.add_argument("--platform", required=True, choices=("iphoneos", "iphonesimulator"))
    parser.add_argument("--composite-library", type=Path)
    parser.add_argument("--immersal-sdk-dir", type=Path, help="read-only external SDK directory containing ImmersalNative.h")
    parser.add_argument("--smoke-fixture", type=Path)
    parser.add_argument("--simulator", default="booted")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/opencv5-unification/native-verification")
    arguments = parser.parse_args()
    try:
        result = verify_framework(arguments.framework, arguments.platform)
        if arguments.composite_library:
            if arguments.platform != "iphoneos":
                raise ValueError("Immersal composite link must use an iPhoneOS native slice")
            result.update(verify_composite_link(arguments.framework, arguments.composite_library, arguments.log_dir, arguments.immersal_sdk_dir))
        if arguments.smoke_fixture:
            if arguments.platform != "iphonesimulator":
                raise ValueError("native runtime smoke needs a real simulator slice")
            result.update(verify_simulator_smoke(arguments.framework, arguments.smoke_fixture, arguments.simulator, arguments.log_dir))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"FAIL AreaTargetNative: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
