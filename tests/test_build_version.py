"""The displayed version comes from the packaged image, not the browser clock."""

from pathlib import Path
import shutil
import subprocess
import sys

import pytest
from flask import Flask, render_template, send_from_directory

ROOT = Path(__file__).resolve().parents[1]


def package_pages(tmp_path, timestamp):
    web_root = tmp_path / "web_service"
    for name in ("static/index.html", "templates/login.html"):
        target = web_root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "web_service" / name, target)
    result = subprocess.run(
        [sys.executable, str(ROOT / "web_service/build_version.py"),
         "--web-root", str(web_root), "--build-time", timestamp],
        capture_output=True, text=True,
    )
    return web_root, result


@pytest.mark.parametrize("timestamp", ["2026-10-08T18:05:37Z", "2026-10-09T02:05:37+08:00"])
def test_packaged_pages_show_same_fixed_build_time_across_requests(tmp_path, timestamp):
    web_root, result = package_pages(tmp_path, timestamp)
    assert result.returncode == 0, result.stderr
    app = Flask(__name__, static_folder=str(web_root / "static"),
                template_folder=str(web_root / "templates"))
    app.add_url_rule("/", "index", lambda: send_from_directory(web_root / "static", "index.html"))
    app.add_url_rule("/login", "login", lambda: render_template("login.html"))
    client = app.test_client()
    for route in ("/", "/login", "/", "/login"):
        response = client.get(route)
        assert response.status_code == 200
        html = response.get_data(as_text=True)
        assert "版本：2026-10-09 02:05:37（UTC+8）" in html
        assert 'datetime="2026-10-08T18:05:37Z"' in html
        assert "开发版（未打包）" not in html


@pytest.mark.parametrize("timestamp", ["2026-10-08T18:05:37", "<script>alert(1)</script>"])
def test_invalid_or_ambiguous_build_time_fails_without_stamping(tmp_path, timestamp):
    web_root, result = package_pages(tmp_path, timestamp)
    assert result.returncode != 0
    assert "Build time" in result.stderr
    for name in ("static/index.html", "templates/login.html"):
        assert (web_root / name).read_bytes() == (ROOT / "web_service" / name).read_bytes()


def test_malformed_second_page_does_not_partially_stamp_first_page(tmp_path):
    web_root, result = package_pages(tmp_path, "2026-10-08T18:05:37Z")
    assert result.returncode == 0, result.stderr
    login_page = web_root / "templates/login.html"
    html = login_page.read_text(encoding="utf-8")
    html = html.replace("<!-- build-version -->", "<!-- swapped -->").replace("<!-- /build-version -->", "<!-- build-version -->").replace("<!-- swapped -->", "<!-- /build-version -->")
    login_page.write_text(html, encoding="utf-8")
    before = (web_root / "static/index.html").read_bytes()
    result = subprocess.run(
        [sys.executable, str(ROOT / "web_service/build_version.py"),
         "--web-root", str(web_root), "--build-time", "2026-10-09T18:05:37Z"],
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "build version marker" in result.stderr
    assert (web_root / "static/index.html").read_bytes() == before
