import hashlib
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/phase0/build_upm_package.py"
OUTPUT = ROOT / "dist/com.areatarget.tracking-1.2.1.tgz"

REQUIRED = {
    "package/package.json",
    "package/Runtime/AlignmentTransformCalculator.cs",
    "package/Runtime/ExtendedDebugInfo.cs",
    "package/Runtime/GLBMeshLoader.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
    "package/Runtime/Plugins/macOS/libvisual_localizer.dylib",
}


def build():
    subprocess.run([sys.executable, str(BUILDER)], cwd=ROOT, check=True)
    return hashlib.sha256(OUTPUT.read_bytes()).hexdigest()


def test_package_content_and_reproducibility():
    first = build()
    second = build()
    assert first == second
    with tarfile.open(OUTPUT, "r:gz") as archive:
        names = set(archive.getnames())
    assert REQUIRED <= names
    assert not any("/Tests" in name or "/PropertyTests" in name for name in names)
    assert not any(name.endswith((".unitypackage", ".tgz", ".bak2")) for name in names)
