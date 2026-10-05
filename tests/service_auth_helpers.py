"""Authenticated clients for tests that exercise the independent job contract."""
from werkzeug.security import generate_password_hash

from web_service.auth import AuthManager

PASSWORD_HASH = generate_password_hash("route-test-password-42", method="scrypt:32768:8:1")


def authenticate_test_clients(monkeypatch, tmp_path, app):
    manager = AuthManager("test-admin", PASSWORD_HASH, str(tmp_path / "service_auth.sqlite"))
    monkeypatch.setitem(app.extensions, "area_target_auth", manager)
    token, _ = manager.create_session()
    original = app.test_client

    def test_client(*args, **kwargs):
        client = original(*args, **kwargs)
        client.environ_base["HTTP_X_AREA_TARGET_SESSION"] = token
        return client

    monkeypatch.setattr(app, "test_client", test_client)
