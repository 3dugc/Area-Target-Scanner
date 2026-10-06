#!/usr/bin/env python3
"""Generate synthetic fixtures with an explicit OpenCV 5 + contrib install.

Set OpenCV_DIR or pass --opencv-dir to the pinned dependency's lib/cmake/opencv5.
No Homebrew lookup, downloads, saved scans or Simulator operations occur here.
The existing fixture.bin/SQLite schema is preserved. fixture-akaze.bin is an
additional test-only input for the real native AKAZE fallback.
"""
import argparse
import hashlib
import json
import math
import re
import os
import shlex
import sqlite3
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIDTH, HEIGHT = 640, 480
EXPECTED_POSE = [1, 0, 0, .15, 0, 1, 0, -.23, 0, 0, 1, .34, 0, 0, 0, 1]
SCHEMA = """
CREATE TABLE keyframes (id INTEGER PRIMARY KEY, pose BLOB NOT NULL, global_descriptor BLOB);
CREATE TABLE features (
    id INTEGER PRIMARY KEY, keyframe_id INTEGER NOT NULL REFERENCES keyframes(id),
    x REAL NOT NULL, y REAL NOT NULL, x3d REAL NOT NULL, y3d REAL NOT NULL,
    z3d REAL NOT NULL, descriptor BLOB NOT NULL);
CREATE TABLE vocabulary (word_id INTEGER PRIMARY KEY, descriptor BLOB NOT NULL, idf_weight REAL NOT NULL);
"""


def temporary_path(value):
    path = Path(value).expanduser().resolve()
    if path in (Path("/private/tmp"), ROOT / "build") or not (path.is_relative_to(Path("/private/tmp")) or path.is_relative_to(ROOT / "build")):
        raise ValueError("fixture output/build directories must be children of /private/tmp or repository build/")
    return path


def run(arguments, log=None):
    result = subprocess.run([str(item) for item in arguments], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError("command failed: " + shlex.join([str(item) for item in arguments]) + "\n" + result.stdout)
    return result.stdout.strip()


def validate_host_opencv(opencv_dir):
    opencv_dir = Path(opencv_dir).expanduser().resolve()
    prefix = opencv_dir.parents[2]
    version = (prefix / "include/opencv5/opencv2/core/version.hpp").read_text()
    for name, number in (("MAJOR", 5), ("MINOR", 0), ("REVISION", 0)):
        if not re.search(r"^#define CV_VERSION_" + name + r"\s+" + str(number) + r"\s*$", version, re.M):
            raise ValueError("fixture requires the pinned OpenCV 5.0.0 install")
    if not (prefix / "include/opencv5/opencv2/xfeatures2d.hpp").is_file():
        raise ValueError("fixture requires OpenCV 5 contrib AKAZE")
    libraries = sorted((prefix / "lib").glob("libopencv_*.a"))
    if not (prefix / "lib/libopencv_xfeatures2d.a").is_file():
        raise ValueError("fixture requires static OpenCV 5 contrib libraries")
    provenance = {str(path.name): hashlib.sha256(path.read_bytes()).hexdigest() for path in libraries}
    return opencv_dir, provenance


def host_generator(build_directory, opencv_dir):
    opencv_dir, provenance = validate_host_opencv(opencv_dir)
    compiler = run(["xcrun", "--sdk", "macosx", "--find", "clang++"])
    native = ROOT / "native_visual_localizer"
    sources = [Path(__file__).with_suffix(".cpp")] + [native / "src" / name for name in
                ("pose_contract.cpp", "visual_localizer.cpp", "visual_localizer_impl.cpp")]
    inputs = sources + sorted((native / "src").glob("*.h")) + sorted((native / "include").glob("*.h"))
    key = hashlib.sha256(json.dumps([str(opencv_dir), provenance, compiler, run([compiler, "--version"])]).encode())
    for path in inputs:
        key.update(path.read_bytes())
    cache = build_directory / key.hexdigest()[:20]
    cache.mkdir(parents=True, exist_ok=True)
    executable = cache / "generate_native_fixture"
    quoted_sources = "\n".join('  "' + str(path) + '"' for path in sources)
    cmake = "cmake_minimum_required(VERSION 3.16)\nproject(NativeFixture LANGUAGES CXX)\n"
    cmake += "set(CMAKE_CXX_STANDARD 17)\nfind_package(OpenCV 5.0.0 EXACT CONFIG REQUIRED COMPONENTS core imgproc features geometry xfeatures2d)\n"
    cmake += "add_executable(generate_native_fixture\n" + quoted_sources + "\n)\n"
    cmake += 'target_include_directories(generate_native_fixture PRIVATE "' + str(native / "include") + '" "' + str(native / "src") + '" ${OpenCV_INCLUDE_DIRS})\n'
    cmake += "target_link_libraries(generate_native_fixture PRIVATE ${OpenCV_LIBS})\n"
    (cache / "CMakeLists.txt").write_text(cmake)
    if not executable.is_file():
        run(["cmake", "-S", cache, "-B", cache, "-DOpenCV_DIR=" + str(opencv_dir),
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CXX_COMPILER=" + compiler], cache / "configure.log")
        run(["cmake", "--build", cache, "--parallel", "2"], cache / "compile.log")
    return executable, cache, "5.0.0", provenance


def publish_fixture(staging, smoke):
    data = (staging / "fixture.bin").read_bytes()
    count = struct.unpack_from("<i", data)[0]
    expected_size = 4 + WIDTH * HEIGHT + count * (32 + 3 * 4 + 2 * 4)
    if count != 2000 or count != smoke["featureCount"] or len(data) != expected_size:
        raise ValueError("native binary has wrong feature count or layout")
    image_end = 4 + WIDTH * HEIGHT
    descriptors_end = image_end + count * 32
    points_end = descriptors_end + count * 12
    image = data[4:image_end]
    descriptors = data[image_end:descriptors_end]
    xyz = list(struct.iter_unpack("<3f", data[descriptors_end:points_end]))
    xy = list(struct.iter_unpack("<2f", data[points_end:]))
    if not all(math.isfinite(value) for point in xyz + xy for value in point):
        raise ValueError("nonfinite synthetic coordinates")
    with sqlite3.connect(staging / "features.db") as database:
        database.executescript(SCHEMA)
        inverse_pose = list(EXPECTED_POSE)
        for index in (3, 7, 11):
            inverse_pose[index] = -inverse_pose[index]
        database.execute("INSERT INTO keyframes VALUES (?,?,?)", (7, struct.pack("<16d", *inverse_pose), None))
        database.executemany("INSERT INTO vocabulary VALUES (?,?,?)",
                             ((i, descriptors[i * 32:(i + 1) * 32], 1.0) for i in range(count)))
        database.executemany("INSERT INTO features VALUES (?,?,?,?,?,?,?,?)",
                             ((i + 1, 7, *xy[i], *xyz[i], descriptors[i * 32:(i + 1) * 32]) for i in range(count)))
        database.commit()
        if database.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("synthetic SQLite quick_check failed")
    (staging / "query.gray8").write_bytes(image)
    metadata = {
        "fixtureSchemaVersion": 1, "syntheticOnly": True, "rngSeed": 20261004,
        "width": WIDTH, "height": HEIGHT, "intrinsics": {"fx": 500, "fy": 510, "cx": 320, "cy": 240},
        "keyframeId": 7, "featureCount": count,
        "training": "raw grayscale ORB2000; synthetic descriptor vocabulary; native query ORB3000",
        "query": "query.gray8", "expectedCameraFromScan": EXPECTED_POSE,
        "minimumMatchedFeatures": 100, "maxPoseElementTolerance": .01,
        "producerOpenCVVersion": smoke["producerOpenCVVersion"], "nativeSmoke": smoke,
        "opencvLibrarySHA256s": smoke["opencvLibrarySHA256s"],
        "querySHA256": hashlib.sha256(image).hexdigest(),
    }
    (staging / "fixture.json").write_text(json.dumps(metadata, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--opencv-dir", type=Path, default=os.environ.get("OpenCV_DIR", ROOT / "build/opencv5/install/lib/cmake/opencv5"))
    parser.add_argument("--output-dir", default=str(ROOT / "build/opencv5-unification/fixture"))
    parser.add_argument("--build-dir", default=str(ROOT / "build/opencv5-unification/fixture-generator"))
    arguments = parser.parse_args()
    output = temporary_path(arguments.output_dir)
    build = temporary_path(arguments.build_dir)
    output.mkdir(parents=True, exist_ok=True)
    executable, cache, version, provenance = host_generator(build, arguments.opencv_dir)
    with tempfile.TemporaryDirectory(prefix=".native-fixture-", dir=output.parent) as temporary:
        staging = Path(temporary)
        smoke = json.loads(run([executable, staging / "fixture.bin"], cache / "native-smoke.log"))
        if smoke["producerOpenCVVersion"] != version:
            raise ValueError("OpenCV header and pinned dependency versions disagree")
        (staging / "fixture.bin.akaze").replace(staging / "fixture-akaze.bin")
        smoke["opencvLibrarySHA256s"] = provenance
        publish_fixture(staging, smoke)
        for name in ("fixture.bin", "fixture-akaze.bin", "query.gray8", "features.db", "fixture.json"):
            os.replace(staging / name, output / name)
    print(json.dumps({"outputDirectory": str(output), "buildDirectory": str(cache), "nativeSmoke": smoke}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, struct.error, sqlite3.Error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
