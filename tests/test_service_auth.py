"""The service login must gate work before reading uploads or job records."""
import hashlib
import sqlite3
from datetime import datetime

import pytest
from flask import Flask, jsonify
from werkzeug.security import generate_password_hash

PASSWORD = "test-password-with-entropy-42"
PASSWORD_HASH = generate_password_hash(PASSWORD, method="scrypt:32768:8:1")


def make_app(tmp_path, monkeypatch, configured=True):
    from web_service.auth import register_auth

    monkeypatch.setenv("AREA_TARGET_USERNAME", "admin" if configured else "")
    monkeypatch.setenv("AREA_TARGET_PASSWORD_HASH", PASSWORD_HASH if configured else "")
    app = Flask(__name__)
    app.config["TESTING"] = True
    app.config["SIDE_EFFECTS"] = 0

    def protected():
        app.config["SIDE_EFFECTS"] += 1
        return jsonify(ok=True)

    for i, path in enumerate(("/", "/api/upload", "/api/status/test", "/api/download/test",
                               "/api/v1/jobs", "/api/v1/jobs/test", "/api/v1/jobs/test/result",
                               "/api/v1/processing-requirements", "/api/v1/openapi.json", "/future-route")):
        app.add_url_rule(path, f"protected_{i}", protected, methods=["GET", "POST"])
    register_auth(app, str(tmp_path / "auth.sqlite"))
    return app


@pytest.fixture
def app(tmp_path, monkeypatch):
    return make_app(tmp_path, monkeypatch)


def login(client, **kwargs):
    return client.post("/api/auth/login", json={"username": "admin", "password": PASSWORD, **kwargs})


@pytest.mark.parametrize("path", ["/api/upload", "/api/status/test", "/api/download/test", "/api/v1/jobs",
                                  "/api/v1/jobs/test", "/api/v1/jobs/test/result",
                                  "/api/v1/processing-requirements", "/api/v1/openapi.json"])
def test_anonymous_api_cannot_reach_work(app, path):
    response = app.test_client().post(path)
    assert response.status_code == 401
    assert "authentication_required" in response.get_data(as_text=True)
    assert app.config["SIDE_EFFECTS"] == 0


@pytest.mark.parametrize("path", ["/", "/static/index.html", "/future-route"])
def test_every_page_and_static_bypass_is_gated(app, path):
    response = app.test_client().get(path)
    assert response.status_code == 302 and response.headers["Location"] == "/login"
    assert app.config["SIDE_EFFECTS"] == 0


def test_unconfigured_service_fails_closed_even_in_testing(tmp_path, monkeypatch):
    app = make_app(tmp_path, monkeypatch, configured=False)
    client = app.test_client()
    for path in ("/", "/api/upload", "/api/v1/jobs", "/api/auth/login"):
        assert client.post(path).status_code == 503
    assert client.get("/healthz").json == {"status": "ok"}
    assert app.config["SIDE_EFFECTS"] == 0


def test_wrong_password_and_wrong_username_are_indistinguishable(app):
    client = app.test_client()
    wrong_password = login(client, password="incorrect")
    wrong_username = login(client, username="nobody")
    assert wrong_password.status_code == wrong_username.status_code == 401
    assert wrong_password.json == wrong_username.json
    assert "Set-Cookie" not in wrong_password.headers


def test_success_has_secure_cookie_and_distinct_csrf(app, tmp_path):
    client = app.test_client()
    response = login(client)
    assert response.status_code == 200
    data = response.json
    assert data["username"] == "admin"
    assert len(data["session_token"]) == 64 and len(data["csrf_token"]) == 64
    assert data["session_token"] != data["csrf_token"]
    assert datetime.fromisoformat(data["expires_at"]).tzinfo is not None
    cookie = response.headers["Set-Cookie"]
    assert all(option in cookie for option in ("Secure", "HttpOnly", "SameSite=Strict"))
    with sqlite3.connect(tmp_path / "auth.sqlite") as conn:
        rows = conn.execute("SELECT * FROM sessions").fetchall()
    assert data["session_token"] not in str(rows) and PASSWORD not in str(rows)
    assert hashlib.sha256(data["session_token"].encode()).hexdigest() in str(rows)
    assert client.get("/").status_code == 200
    metadata = client.get("/api/auth/session").json
    assert metadata["username"] == "admin" and metadata["csrf_token"] == data["csrf_token"]
    assert "session_token" not in metadata


def test_native_header_works_without_cookie_or_overwriting_job_bearer(app):
    token = login(app.test_client()).json["session_token"]
    client = app.test_client(use_cookies=False)
    headers = {"X-Area-Target-Session": token, "Authorization": "Bearer " + "a" * 64}
    assert client.post("/api/v1/jobs", headers=headers).status_code == 200
    assert client.get("/api/auth/session", headers=headers).status_code == 200
    assert client.post("/api/v1/jobs", headers={"Authorization": "Bearer " + "a" * 64}).status_code == 401
    assert client.post("/api/v1/jobs?session_token=" + token).status_code == 401


def test_cookie_mutations_require_csrf_and_invalid_header_never_falls_back(app):
    client = app.test_client()
    data = login(client).json
    assert client.post("/api/upload").status_code == 403
    assert client.post("/api/upload", headers={"X-CSRF-Token": "wrong"}).status_code == 403
    assert client.post("/api/upload", headers={"X-CSRF-Token": data["csrf_token"]}).status_code == 200
    assert client.get("/api/auth/session", headers={"X-Area-Target-Session": ""}).status_code == 401
    assert client.get("/api/auth/session", headers={"X-Area-Target-Session": "invalid"}).status_code == 401
    assert client.post("/api/auth/logout").status_code == 403


def test_logout_revokes_header_and_cookie(app):
    client = app.test_client()
    data = login(client).json
    response = client.post("/api/auth/logout", headers={"X-CSRF-Token": data["csrf_token"]})
    assert response.status_code == 200 and response.json == {"ok": True}
    assert client.get("/api/auth/session").status_code == 401
    assert app.test_client(use_cookies=False).get("/api/auth/session", headers={
        "X-Area-Target-Session": data["session_token"]}).status_code == 401


def test_expiry_and_password_rotation_revoke_sessions(app, tmp_path, monkeypatch):
    import web_service.auth as auth
    now = auth.time.time()
    client = app.test_client()
    data = login(client).json
    monkeypatch.setattr(auth.time, "time", lambda: now + 12 * 3600 + 1)
    assert client.get("/api/auth/session").status_code == 401
    monkeypatch.setattr(auth.time, "time", lambda: now)
    data = login(client).json
    from web_service.auth import AuthManager
    monkeypatch.setitem(app.extensions, "area_target_auth", AuthManager("changed-admin", PASSWORD_HASH, str(tmp_path / "auth.sqlite")))
    assert app.test_client(use_cookies=False).get("/api/auth/session", headers={
        "X-Area-Target-Session": data["session_token"]}).status_code == 401


def test_login_limits_persist_across_manager_recreation_and_do_not_trust_forwarded_ip(app, tmp_path, monkeypatch):
    from web_service.auth import AuthManager
    client = app.test_client()
    for i in range(10):
        assert client.post("/api/auth/login", json={"username": "admin", "password": "wrong"},
                           headers={"X-Forwarded-For": f"192.0.2.{i}"}).status_code == 401
    monkeypatch.setitem(app.extensions, "area_target_auth", AuthManager("admin", PASSWORD_HASH, str(tmp_path / "auth.sqlite")))
    response = login(client)
    assert response.status_code == 429 and int(response.headers["Retry-After"]) > 0


def test_login_body_is_small_json_only_and_cross_site_is_rejected(app):
    client = app.test_client()
    assert client.post("/api/auth/login", data={"username": "admin", "password": PASSWORD}).status_code == 415
    assert client.post("/api/auth/login", json={"username": "admin", "password": "x" * 9000}).status_code == 413
    assert client.post("/api/auth/login", data="{", content_type="application/json").status_code == 400
    assert client.post("/api/auth/login", json=["admin", PASSWORD]).status_code == 400
    assert client.post("/api/auth/login", json={"username": "admin", "password": PASSWORD},
                       headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post("/api/auth/login", json={"username": "admin", "password": PASSWORD},
                       headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403


def test_malformed_origin_and_invalid_unicode_credentials_are_client_errors(app):
    client = app.test_client()
    assert client.post("/api/auth/login", json={"username": "admin", "password": PASSWORD},
                       headers={"Origin": "http://["}).status_code == 403
    assert login(client, username="\ud800").status_code == 400
    assert login(client, password="\ud800").status_code == 400
    deeply_nested = "[" * 1100 + "0" + "]" * 1100
    assert client.post("/api/auth/login", data=deeply_nested, content_type="application/json").status_code == 400


def test_no_store_on_login_authenticated_pages_errors_and_health(app):
    client = app.test_client()
    for response in (login(client), client.get("/"), client.get("/healthz"),
                     app.test_client(use_cookies=False).get("/api/status/test")):
        assert response.headers["Cache-Control"] == "no-store"
        assert response.headers["X-Content-Type-Options"] == "nosniff"
        assert response.headers["X-Frame-Options"] == "DENY"
