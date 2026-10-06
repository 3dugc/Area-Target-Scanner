#!/usr/bin/env python3
"""Mac end-to-end contract test; uses installed OpenCV and real native sources."""
import json
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

GENERATOR = Path(__file__).with_name("generate_native_fixture.py")

class NativeFixtureGeneratorTests(unittest.TestCase):
    def test_fresh_generator_emits_production_schema_and_real_known_pose_smoke(self):
        self.assertTrue(GENERATOR.is_file(), "repeatable repository fixture generator is missing")
        with tempfile.TemporaryDirectory(prefix="native-fixture-generator-test-", dir="/private/tmp") as temporary:
            output = Path(temporary) / "fixture"
            result = subprocess.run(["/usr/bin/python3", str(GENERATOR), "--output-dir", str(output)],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)
            metadata = json.loads((output / "fixture.json").read_text())
            self.assertEqual(metadata["producerOpenCVVersion"], "5.0.0")
            self.assertEqual(metadata["nativeSmoke"]["akazeState"], 1)
            self.assertEqual(metadata["nativeSmoke"]["akazeTriggered"], 1)
            self.assertGreaterEqual(metadata["nativeSmoke"]["akazeMatchedFeatures"], 8)
            self.assertLess(metadata["nativeSmoke"]["akazeMaxPoseElementError"], .01)
            self.assertTrue((output / "fixture-akaze.bin").is_file())
            self.assertEqual(metadata["featureCount"], 2000)
            self.assertEqual((metadata["width"], metadata["height"]), (640, 480))
            self.assertTrue(metadata["syntheticOnly"])
            smoke = metadata["nativeSmoke"]
            self.assertEqual(smoke["state"], 1)
            self.assertGreaterEqual(smoke["matchedFeatures"], metadata["minimumMatchedFeatures"])
            self.assertLess(smoke["maxPoseElementError"], metadata["maxPoseElementTolerance"])
            self.assertEqual(smoke["blankState"], 2)
            self.assertEqual(smoke["blankMatchedFeatures"], 0)
            self.assertEqual(smoke["blankConfidence"], 0)
            self.assertEqual(len((output / "query.gray8").read_bytes()), 640 * 480)
            binary = (output / "fixture.bin").read_bytes()
            self.assertEqual(struct.unpack_from("<i", binary)[0], 2000)
            self.assertEqual(len(binary), 4 + 640 * 480 + 2000 * (32 + 12 + 8))
            with sqlite3.connect("file:" + str(output / "features.db") + "?mode=ro", uri=True) as database:
                self.assertEqual(database.execute("PRAGMA quick_check").fetchone()[0], "ok")
                self.assertEqual(database.execute("SELECT COUNT(*) FROM features").fetchone()[0], 2000)
                self.assertEqual(database.execute("SELECT COUNT(*) FROM vocabulary").fetchone()[0], 2000)
                pose = database.execute("SELECT pose FROM keyframes WHERE id=7").fetchone()[0]
                self.assertEqual(len(pose), 128)
                values = struct.unpack("<16d", pose)
                self.assertAlmostEqual(values[3], -0.15)
                self.assertAlmostEqual(values[7], 0.23)
                self.assertAlmostEqual(values[11], -0.34)
                depths = database.execute("SELECT MIN(z3d),MAX(z3d) FROM features").fetchone()
                self.assertGreater(depths[1] - depths[0], 1)

if __name__ == "__main__":
    unittest.main()
