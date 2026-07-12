import re
import subprocess

FORBIDDEN = [
    re.compile(r"^unity_project/mono_crash\..*\.json$"),
    re.compile(r"^unity_project/(?:.*?/)?(?:TestResults|test_results|unity_test_results|pbt_).*\.xml$"),
    re.compile(r"\.(?:bak2|data1_bak)(?:\.meta)?$"),
    re.compile(r"^unity_project/unity_project/"),
]


def test_generated_artifacts_are_not_tracked():
    tracked = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
    violations = [
        path for path in tracked if any(pattern.search(path) for pattern in FORBIDDEN)
    ]
    assert violations == []
