"""Contracts for accepting only pinned OpenCV 5 + contrib Apple dependencies."""
import hashlib
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import build_area_target_native as builder

SOURCE = "b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095"
CONTRIB = "c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f"


class DependencyContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.framework = Path(self.temporary.name) / "opencv2.framework"
        (self.framework / "Headers/core").mkdir(parents=True)
        (self.framework / "Headers/core/version.hpp").write_text(
            "#define CV_VERSION_MAJOR 5\n#define CV_VERSION_MINOR 0\n#define CV_VERSION_REVISION 0\n")
        (self.framework / "Headers/xfeatures2d.hpp").write_text("// AKAZE\n")
        (self.framework / "Licenses").mkdir()
        for name in ("OpenCV-LICENSE.txt", "OpenCV-Contrib-LICENSE.txt", "AKAZE-LICENSE.txt", "KAZE-LICENSE.txt"):
            (self.framework / "Licenses" / name).write_text(name + " upstream license\n")
        (self.framework / "opencv2").write_bytes(b"synthetic archive for provenance contract")
        self.metadata = {"version": "5.0.0", "platform": "iphoneos", "architecture": "arm64",
                         "sourceSHA256": SOURCE, "contribSHA256": CONTRIB,
                         "modules": ["core", "imgproc", "features", "geometry", "xfeatures2d"],
                         "binarySHA256": hashlib.sha256((self.framework / "opencv2").read_bytes()).hexdigest()}
        self.write_metadata()

        self.metadata["licenseSHA256s"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                           for path in (self.framework / "Licenses").iterdir()}
        self.write_metadata()

    def write_metadata(self):
        (self.framework / "dependency.json").write_text(json.dumps(self.metadata))

    def validate(self, platform="iphoneos"):
        self.assertTrue(callable(getattr(builder, "validate_opencv_framework", None)),
                        "dependency acceptance must validate source/contrib provenance and bytes")
        return builder.validate_opencv_framework(self.framework, platform)

    def test_accepts_matching_pinned_contrib_dependency(self):
        self.assertEqual(self.validate()["version"], "5.0.0")

    def test_rejects_old_four_dependency(self):
        self.metadata["version"] = "4.10.0"
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, "5.0.0"):
            self.validate()

    def test_rejects_basic_five_without_akaze(self):
        (self.framework / "Headers/xfeatures2d.hpp").unlink()
        with self.assertRaisesRegex(ValueError, "contrib|xfeatures2d"):
            self.validate()

    def test_rejects_wrong_contrib_source(self):
        self.metadata["contribSHA256"] = "0" * 64
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, "contrib"):
            self.validate()

    def test_rejects_wrong_core_source(self):
        self.metadata["sourceSHA256"] = "0" * 64
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, "source"):
            self.validate()

    def test_rejects_wrong_platform_cache(self):
        with self.assertRaisesRegex(ValueError, "platform"):
            self.validate("iphonesimulator")

    def test_rejects_changed_archive(self):
        (self.framework / "opencv2").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "binary|SHA256"):
            self.validate()

    def test_rejects_missing_contrib_license(self):
        (self.framework / "Licenses/OpenCV-Contrib-LICENSE.txt").unlink()
        with self.assertRaisesRegex(ValueError, "license|License"):
            self.validate()

    def test_rejects_changed_dependency_license_bytes(self):
        (self.framework / "Licenses/AKAZE-LICENSE.txt").write_text("modified license")
        with self.assertRaisesRegex(ValueError, "license|License"):
            self.validate()

    def test_explicit_dependency_without_provenance_is_rejected_before_build(self):
        (self.framework / "dependency.json").unlink()
        with mock.patch.object(builder.subprocess, "run", side_effect=AssertionError("explicit dependency must not be overwritten")):
            with self.assertRaisesRegex(ValueError, "provenance"):
                builder.opencv_dependency(Path(self.temporary.name), "iphoneos", 2, self.framework)

    def test_rejects_missing_licenses(self):
        (self.framework / "Licenses/OpenCV-LICENSE.txt").unlink()
        with self.assertRaisesRegex(ValueError, "license|License"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
