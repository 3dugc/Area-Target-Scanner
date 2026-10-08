"""Stamp both web pages once while the service image is being packaged."""

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path

START = "<!-- build-version -->"
END = "<!-- /build-version -->"


def stamp_build_version(web_root: Path, build_time: str) -> None:
    try:
        instant = datetime.fromisoformat(build_time.replace("Z", "+00:00")) if build_time else datetime.now(timezone.utc)
    except ValueError as exc:
        raise ValueError("Build time must be an ISO 8601 timestamp with a timezone") from exc
    if instant.tzinfo is None:
        raise ValueError("Build time must include a timezone")
    instant = instant.astimezone(timezone.utc).replace(microsecond=0)
    utc = instant.isoformat().replace("+00:00", "Z")
    local = instant.astimezone(timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M:%S")
    version = f'<time datetime="{utc}">版本：{local}（UTC+8）</time>'
    pages = []
    for name in ("static/index.html", "templates/login.html"):
        path = web_root / name
        html = path.read_text(encoding="utf-8")
        if html.count(START) != 1 or html.count(END) != 1 or html.index(START) > html.index(END):
            raise ValueError(f"Missing unique build version marker in {name}")
        before, _, tail = html.partition(START)
        _, _, after = tail.partition(END)
        pages.append((path, before + START + version + END + after))
    for path, html in pages:
        path.write_text(html, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--build-time", default="")
    args = parser.parse_args()
    stamp_build_version(args.web_root, args.build_time)
