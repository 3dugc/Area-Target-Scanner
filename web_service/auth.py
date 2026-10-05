"""Service-wide login, separate from per-job capability authorization."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import getpass
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import sys
import time
from urllib.parse import urlsplit

from flask import g, jsonify, redirect, render_template, request
from werkzeug.exceptions import BadRequest, RequestEntityTooLarge
from werkzeug.security import check_password_hash, generate_password_hash

COOKIE = "area_target_session"
SESSION_HEADER = "X-Area-Target-Session"
SESSION_SECONDS = 12 * 3600
LOGIN_WINDOW_SECONDS = 60
TOKEN_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
PASSWORD_HASH_PATTERN = re.compile(r"scrypt:32768:8:1\$[A-Za-z0-9]{16,64}\$[0-9a-f]{128}\Z")


def _digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat()


def _error(status, code, message):
    if request.path.startswith("/api/v1/"):
        response = jsonify(error={"code": code, "message": message, "retryable": False})
    else:
        response = jsonify(error=message, code=code)
    response.status_code = status
    return response


class AuthManager:
    """Persist only session digests; transactions share limits across threads/restarts."""

    def __init__(self, username, password_hash, db_path, cookie_secure=True):
        self.username = username
        self.password_hash = password_hash
        self.db_path = db_path
        self.cookie_secure = cookie_secure
        self.configured = bool(username and len(username) <= 128 and PASSWORD_HASH_PATTERN.fullmatch(password_hash))
        self.credential_digest = _digest(username + "\0" + password_hash)
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        with self.connect() as conn:
            conn.execute("CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, csrf TEXT NOT NULL, "
                         "expires REAL NOT NULL, credential_digest TEXT NOT NULL)")
            conn.execute("CREATE TABLE IF NOT EXISTS login_attempts (identity TEXT PRIMARY KEY, "
                         "started REAL NOT NULL, count INTEGER NOT NULL)")
        os.chmod(db_path, 0o600)

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.db_path, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 5000")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def attempt(self, address):
        """10 attempts per source and 30 total per minute, before password hashing."""
        now = time.time()
        with self.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("DELETE FROM login_attempts WHERE started <= ?", (now - LOGIN_WINDOW_SECONDS,))
            keys = [("global", 30), ("source:" + _digest(address or "unknown"), 10)]
            for key, limit in keys:
                row = conn.execute("SELECT started, count FROM login_attempts WHERE identity = ?", (key,)).fetchone()
                if row and row["count"] >= limit:
                    return max(1, int(row["started"] + LOGIN_WINDOW_SECONDS - now) + 1)
            for key, _ in keys:
                conn.execute("INSERT INTO login_attempts VALUES (?, ?, 1) "
                             "ON CONFLICT(identity) DO UPDATE SET count = count + 1", (key, now))
        return None

    def create_session(self):
        token, csrf = secrets.token_hex(32), secrets.token_hex(32)
        expires = time.time() + SESSION_SECONDS
        with self.connect() as conn:
            conn.execute("DELETE FROM sessions WHERE expires <= ? OR credential_digest != ?",
                         (time.time(), self.credential_digest))
            conn.execute("INSERT INTO sessions VALUES (?, ?, ?, ?)",
                         (_digest(token), csrf, expires, self.credential_digest))
        return token, {"username": self.username, "csrf_token": csrf, "expires_at": _iso(expires)}

    def lookup(self, token):
        if not isinstance(token, str) or not TOKEN_PATTERN.fullmatch(token):
            return None
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE digest = ? AND expires > ? AND credential_digest = ?",
                               (_digest(token), time.time(), self.credential_digest)).fetchone()
        return dict(row) if row else None

    def revoke(self, token):
        with self.connect() as conn:
            conn.execute("DELETE FROM sessions WHERE digest = ?", (_digest(token),))


def register_auth(app, db_path):
    app.extensions["area_target_auth"] = AuthManager(
        os.environ.get("AREA_TARGET_USERNAME", ""), os.environ.get("AREA_TARGET_PASSWORD_HASH", ""),
        db_path, os.environ.get("AREA_TARGET_COOKIE_SECURE", "1") != "0")

    def manager():
        return app.extensions["area_target_auth"]

    def same_site():
        if request.headers.get("Sec-Fetch-Site") == "cross-site":
            return False
        origin = request.headers.get("Origin")
        if origin is None:
            return True  # Native clients send explicit credentials and no Origin.
        try:
            parsed = urlsplit(origin)
        except ValueError:
            return False
        return parsed.scheme in ("https", "http") and parsed.netloc.lower() == request.host.lower()

    @app.before_request
    def require_login():
        if request.endpoint == "service_health" and request.method in ("GET", "HEAD"):
            return None
        if not manager().configured:
            return _error(503, "auth_not_configured", "管理员尚未配置登录账号。")
        if request.endpoint == "service_login_page" and request.method in ("GET", "HEAD"):
            return None
        if request.endpoint == "service_login" and request.method == "POST":
            return None
        explicit_header = SESSION_HEADER in request.headers
        token = request.headers.get(SESSION_HEADER) if explicit_header else request.cookies.get(COOKIE)
        record = manager().lookup(token)
        if not record:
            if request.path.startswith("/api/") or request.method not in ("GET", "HEAD"):
                return _error(401, "authentication_required", "请先登录服务账号。")
            return redirect("/login")
        g.service_session = record
        g.service_session_token = token
        if request.method not in ("GET", "HEAD", "OPTIONS"):
            if not same_site():
                return _error(403, "invalid_origin", "请求来源无效。")
            csrf = request.headers.get("X-CSRF-Token", "")
            if not explicit_header and not hmac.compare_digest(csrf.encode(), record["csrf"].encode()):
                return _error(403, "csrf_required", "登录验证已失效，请刷新页面后重试。")

    @app.after_request
    def secure_response(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "same-origin"
        return response

    @app.get("/healthz", endpoint="service_health")
    def health():
        return jsonify(status="ok")

    @app.get("/login", endpoint="service_login_page")
    def login_page():
        return render_template("login.html")

    @app.post("/api/auth/login", endpoint="service_login")
    def login():
        retry_after = manager().attempt(request.remote_addr)
        if retry_after:
            response = _error(429, "login_rate_limited", "登录尝试过于频繁，请稍后再试。")
            response.headers["Retry-After"] = str(retry_after)
            return response
        if not same_site():
            return _error(403, "invalid_origin", "请求来源无效。")
        request.max_content_length = 8192
        if not request.is_json:
            return _error(415, "json_required", "登录请求需要 JSON 格式。")
        try:
            data = request.get_json()
        except RequestEntityTooLarge:
            return _error(413, "login_payload_too_large", "登录请求过大。")
        except (BadRequest, RecursionError):
            return _error(400, "invalid_login_request", "登录请求无效。")
        if not isinstance(data, dict):
            return _error(400, "invalid_login_request", "登录请求无效。")
        username, password = data.get("username"), data.get("password")
        if not isinstance(username, str) or not isinstance(password, str) or len(username) > 128 or len(password) > 256:
            return _error(400, "invalid_login_request", "登录请求无效。")
        try:
            username_bytes = username.encode("utf-8")
            password.encode("utf-8")
        except UnicodeEncodeError:
            return _error(400, "invalid_login_request", "登录请求无效。")
        valid_password = check_password_hash(manager().password_hash, password)
        valid_username = hmac.compare_digest(username_bytes, manager().username.encode("utf-8"))
        if not (valid_password and valid_username):
            return _error(401, "invalid_credentials", "用户名或密码错误。")
        token, metadata = manager().create_session()
        response = jsonify(session_token=token, **metadata)
        response.set_cookie(COOKIE, token, max_age=SESSION_SECONDS, secure=manager().cookie_secure,
                            httponly=True, samesite="Strict", path="/")
        return response

    @app.get("/api/auth/session")
    def current_session():
        record = g.service_session
        return jsonify(username=manager().username, csrf_token=record["csrf"], expires_at=_iso(record["expires"]))

    @app.post("/api/auth/logout")
    def logout():
        manager().revoke(g.service_session_token)
        response = jsonify(ok=True)
        response.delete_cookie(COOKIE, path="/", secure=manager().cookie_secure, httponly=True, samesite="Strict")
        return response


def main():
    parser = argparse.ArgumentParser(description="Generate the service password hash without exposing the password.")
    parser.add_argument("command", choices=["hash-password"])
    parser.add_argument("--stdin", action="store_true", help="Read a password from standard input for automated setup.")
    args = parser.parse_args()
    password = sys.stdin.read().rstrip("\r\n") if args.stdin else getpass.getpass("Service password: ")
    if not args.stdin and password != getpass.getpass("Repeat password: "):
        parser.error("Passwords do not match.")
    if not 12 <= len(password) <= 256:
        parser.error("Use a password between 12 and 256 characters.")
    print(generate_password_hash(password, method="scrypt:32768:8:1"))


if __name__ == "__main__":
    main()
