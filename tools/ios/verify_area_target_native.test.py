#!/usr/bin/env python3
"""Mac framework packaging/signing integration gate; never starts a Simulator.

Run: /usr/bin/python3 tools/ios/verify_area_target_native.test.py
Uses the framework builder's pinned OpenCV dependency cache (or its normal
verified preparation). All generated frameworks and ad-hoc signatures stay in
/private/tmp. Both real arm64 iOS slices must pass actual codesign --strict.
"""
import json
import os
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from build_area_target_native import license_resources, verify_license_resources
from verify_area_target_native import verify_framework, REQUIRED

BUILDER = Path(__file__).with_name("build_area_target_native.py")

class NativeFrameworkSigningTests(unittest.TestCase):
    def test_complete_device_and_simulator_frameworks_are_signable(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-", dir="/private/tmp") as temporary:
            for platform in ("iphoneos", "iphonesimulator"):
                with self.subTest(platform=platform):
                    output = Path(temporary) / platform
                    command = ["/usr/bin/python3", str(BUILDER), "--platform", platform,
                               "--output-dir", str(output), "--jobs", "2"]
                    if os.environ.get("AREA_TARGET_NATIVE_CACHE"):
                        command += ["--cache-dir", os.environ["AREA_TARGET_NATIVE_CACHE"]]
                    if os.environ.get("AREA_TARGET_OPENCV_FRAMEWORK_ROOT"):
                        command += ["--opencv-framework", str(Path(os.environ["AREA_TARGET_OPENCV_FRAMEWORK_ROOT"]) / platform / "opencv2.framework")]
                    build = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    self.assertEqual(build.returncode, 0, build.stdout)
                    framework = output / "AreaTargetNative.framework"
                    self.assertEqual(verify_framework(framework, platform)["exportedCFunctions"], len(REQUIRED))
                    metadata = json.loads((framework / "dependency.json").read_text())
                    self.assertEqual(metadata["version"], "5.0.0")
                    self.assertEqual(metadata["binarySHA256"], hashlib.sha256((framework / "AreaTargetNative").read_bytes()).hexdigest())
                    binary = framework / "AreaTargetNative"
                    original_binary = binary.read_bytes()
                    binary.write_bytes(original_binary + b"tampered")
                    with self.assertRaisesRegex(ValueError, "binary SHA256"):
                        verify_framework(framework, platform)
                    binary.write_bytes(original_binary)
                    dependency_notice = framework / "Licenses/AKAZE-LICENSE.txt"
                    original_notice = dependency_notice.read_bytes()
                    dependency_notice.write_bytes(b"tampered dependency license")
                    with self.assertRaisesRegex(ValueError, "license SHA256"):
                        verify_framework(framework, platform)
                    dependency_notice.write_bytes(original_notice)
                    # Signing changes Mach-O bytes; producer provenance is checked before signing.
                    sign = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                                           str(framework)], text=True,
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    self.assertEqual(sign.returncode, 0, sign.stdout)
                    strict = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=4",
                                             str(framework)], text=True,
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    self.assertEqual(strict.returncode, 0, strict.stdout)
                    self.assertFalse((framework / "Resources").exists(), "iOS frameworks must remain flat for installation")
                    verify_license_resources(framework, license_resources())

if __name__ == "__main__":
    unittest.main()
