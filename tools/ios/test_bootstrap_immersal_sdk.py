"""Offline tests for the pinned, local-only Immersal SDK restore tool."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.request


SCRIPT = Path(__file__).with_name("bootstrap_immersal_sdk.py")
PAYLOAD = b"synthetic SDK bytes; never an upstream or distributable binary\n"


class BootstrapContracts(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "the fixed SDK bootstrap tool must exist")
        spec = importlib.util.spec_from_file_location("immersal_bootstrap_under_test", SCRIPT)
        self.sdk = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sdk)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "sdk" / "libPosePlugin.a"
        self.digest = hashlib.sha256(PAYLOAD).hexdigest()
        self.patch = mock.patch.object(self.sdk, "EXPECTED_SHA256", self.digest)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def fetch(self, payload=PAYLOAD):
        return mock.Mock(return_value=io.BytesIO(payload))

    def test_fixed_upstream_identity_matches_existing_product_pin(self):
        self.patch.stop()
        self.assertEqual(self.sdk.PINNED_COMMIT, "6fd5c0bf42c86c35c97630c84df4438388e7f7c8")
        self.assertEqual(self.sdk.EXPECTED_SHA256, "45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f")
        self.assertEqual(self.sdk.ARTIFACT_URL,
                         "https://github.com/immersal/imdk-unity/raw/"
                         + self.sdk.PINNED_COMMIT + "/Runtime/Plugins/iOS/libPosePlugin.a")

    def test_verified_download_is_published_without_temporary_files(self):
        fetch = self.fetch()
        result = self.sdk.bootstrap(self.destination, open_artifact=fetch)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assertEqual(result["status"], "downloaded")
        self.assertEqual(result["sha256"], self.digest)
        self.assertEqual(result["bytes"], len(PAYLOAD))
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])
        fetch.assert_called_once_with()

    def test_matching_cache_is_reused_without_network_or_rewriting(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(PAYLOAD)
        before = self.destination.stat().st_mtime_ns
        fetch = mock.Mock(side_effect=AssertionError("cache hit must stay offline"))
        result = self.sdk.bootstrap(self.destination, open_artifact=fetch)
        self.assertEqual(result["status"], "reused")
        self.assertEqual(self.destination.stat().st_mtime_ns, before)
        fetch.assert_not_called()

    def test_existing_different_bytes_are_preserved_and_rejected(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b"existing unknown SDK")
        fetch = self.fetch()
        with self.assertRaisesRegex(ValueError, "SHA256|checksum"):
            self.sdk.bootstrap(self.destination, open_artifact=fetch)
        self.assertEqual(self.destination.read_bytes(), b"existing unknown SDK")
        fetch.assert_not_called()

    def test_download_checksum_failure_leaves_no_destination_or_partial_file(self):
        with self.assertRaisesRegex(ValueError, "SHA256|checksum"):
            self.sdk.bootstrap(self.destination, open_artifact=self.fetch(b"wrong bytes"))
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_interrupted_download_cleans_up_without_publishing(self):
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                raise OSError("synthetic connection interrupted")
        with self.assertRaisesRegex(OSError, "interrupted"):
            self.sdk.bootstrap(self.destination, open_artifact=lambda: Interrupted(PAYLOAD))
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_destination_symlink_is_rejected_without_touching_target(self):
        target = self.root / "other.a"
        target.write_bytes(PAYLOAD)
        self.destination.parent.mkdir()
        self.destination.symlink_to(target)
        fetch = self.fetch()
        with self.assertRaisesRegex(ValueError, "regular|symlink"):
            self.sdk.bootstrap(self.destination, open_artifact=fetch)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(target.read_bytes(), PAYLOAD)
        fetch.assert_not_called()

    def test_directory_destination_is_rejected(self):
        self.destination.mkdir(parents=True)
        fetch = self.fetch()
        with self.assertRaisesRegex(ValueError, "regular"):
            self.sdk.bootstrap(self.destination, open_artifact=fetch)
        fetch.assert_not_called()

    def test_concurrent_writer_is_never_overwritten(self):
        def racing_fetch():
            self.destination.write_bytes(b"a different writer won")
            return io.BytesIO(PAYLOAD)
        with self.assertRaisesRegex(ValueError, "SHA256|checksum"):
            self.sdk.bootstrap(self.destination, open_artifact=racing_fetch)
        self.assertEqual(self.destination.read_bytes(), b"a different writer won")
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_oversized_download_is_rejected_without_publishing(self):
        with mock.patch.object(self.sdk, "MAX_BYTES", 8):
            with self.assertRaisesRegex(ValueError, "size|large"):
                self.sdk.bootstrap(self.destination, open_artifact=self.fetch())
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_redirect_policy_accepts_only_official_https_hosts(self):
        policy = self.sdk.OfficialArtifactRedirectHandler()
        request = urllib.request.Request(self.sdk.ARTIFACT_URL)
        for url in ("http://raw.githubusercontent.com/immersal/file", "https://example.com/file"):
            with self.assertRaisesRegex(ValueError, "redirect"):
                policy.redirect_request(request, None, 302, "Found", {}, url)
        redirected = policy.redirect_request(request, None, 302, "Found", {},
                                             "https://raw.githubusercontent.com/immersal/file")
        self.assertEqual(redirected.full_url, "https://raw.githubusercontent.com/immersal/file")


if __name__ == "__main__":
    unittest.main()
