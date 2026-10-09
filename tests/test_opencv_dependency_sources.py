import hashlib
import io
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[1] / "tools/opencv5/verify_source.py"


def source_archive(tmp_path):
    archive = tmp_path / "source.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        member = tarfile.TarInfo("project-5.0.0/CMakeLists.txt")
        content = b"project(original)\n"
        member.size = len(content)
        stream.addfile(member, io.BytesIO(content))
    return archive, hashlib.sha256(archive.read_bytes()).hexdigest(), tmp_path / "project-5.0.0"


def verify(archive, digest, source, python=sys.executable):
    return subprocess.run([python, str(HELPER), str(archive), digest, str(source)],
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


@pytest.mark.skipif(sys.platform != "darwin", reason="Xcode system Python is macOS-only")
def test_fresh_source_extracts_and_reuses_with_xcode_system_python(tmp_path):
    archive, digest, source = source_archive(tmp_path)
    first = verify(archive, digest, source, "/usr/bin/python3")
    assert first.returncode == 0, first.stderr
    assert (source / "CMakeLists.txt").read_text() == "project(original)\n"
    second = verify(archive, digest, source, "/usr/bin/python3")
    assert second.returncode == 0, second.stderr


@pytest.mark.parametrize("kind", ["parent", "symlink", "hardlink", "fifo"])
def test_unsafe_archive_members_are_rejected_before_any_extraction(tmp_path, kind):
    archive, _, source = source_archive(tmp_path)
    with tarfile.open(archive, "w:gz") as stream:
        safe = tarfile.TarInfo("project-5.0.0/first.txt")
        safe.size = 4
        stream.addfile(safe, io.BytesIO(b"safe"))
        member = tarfile.TarInfo("project-5.0.0/unsafe")
        if kind == "parent":
            member.name = "project-5.0.0/../outside.txt"
            member.size = 3
            stream.addfile(member, io.BytesIO(b"bad"))
        else:
            member.type = {"symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE,
                           "fifo": tarfile.FIFOTYPE}[kind]
            member.linkname = "first.txt"
            stream.addfile(member)
    expected = hashlib.sha256(archive.read_bytes()).hexdigest()
    result = verify(archive, expected, source)
    assert result.returncode != 0
    assert not source.exists(), "validate every member before writing any source file"
    assert not (tmp_path / "outside.txt").exists()
