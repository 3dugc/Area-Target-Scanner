import hashlib
import io
import subprocess
import sys
import tarfile
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "tools/opencv5/verify_source.py"


def source_archive(tmp_path):
    archive = tmp_path / "source.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        member = tarfile.TarInfo("project-5.0.0/CMakeLists.txt")
        content = b"project(original)\n"
        member.size = len(content)
        stream.addfile(member, io.BytesIO(content))
    return archive, hashlib.sha256(archive.read_bytes()).hexdigest(), tmp_path / "project-5.0.0"


def verify(archive, digest, source):
    return subprocess.run([sys.executable, str(HELPER), str(archive), digest, str(source)],
                          capture_output=True, text=True)


def test_verified_archive_extracts_and_reuses_identical_source(tmp_path):
    archive, digest, source = source_archive(tmp_path)
    assert verify(archive, digest, source).returncode == 0
    assert (source / "CMakeLists.txt").read_text() == "project(original)\n"
    assert verify(archive, digest, source).returncode == 0


def test_modified_or_extra_source_cannot_claim_archive_identity(tmp_path):
    archive, digest, source = source_archive(tmp_path)
    assert verify(archive, digest, source).returncode == 0
    (source / "CMakeLists.txt").write_text("project(modified)\n")
    assert verify(archive, digest, source).returncode != 0
    (source / "CMakeLists.txt").write_text("project(original)\n")
    (source / "extra.cpp").write_text("void surprise() {}\n")
    assert verify(archive, digest, source).returncode != 0


def test_bad_archive_digest_fails_before_extracting(tmp_path):
    archive, _, source = source_archive(tmp_path)
    assert verify(archive, "0" * 64, source).returncode != 0
    assert not source.exists()
