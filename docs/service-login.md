# Service login

When this login-enabled image is deployed, the service at https://at.3dugc.com requires one deployment-configured username and password for the web upload page and all processing APIs. The legacy hostname is `area-target.p.01xr.com`. No default production credentials are supplied. An unconfigured service rejects page and API requests with HTTP 503; only its minimal health endpoint remains available. Local verification does not confirm that either online deployment has been updated.

## Configure credentials

Set `AREA_TARGET_USERNAME` to the account name you choose. Generate `AREA_TARGET_PASSWORD_HASH` with the service's password helper:

```bash
python -m web_service.auth hash-password
```

The helper prompts for and confirms a password between 12 and 256 characters without echoing it. It prints a Werkzeug scrypt hash; store that hash in the deployment environment. The username must be at most 128 characters. The plaintext password is used only to log in. With an already built image, the same helper is available without starting the web service:

```bash
docker run --rm -it --entrypoint python \
  hkccr.ccs.tencentyun.com/plugins/area-target-scanner:publish \
  -m web_service.auth hash-password
```

In Portainer, set `AREA_TARGET_USERNAME` and `AREA_TARGET_PASSWORD_HASH` as stack environment variables before updating the scanner image. Both are required by `docker-compose.portainer.yml`. Keep the existing live stack's routes, resource limits, image pins and volumes. The production stack uses `AREA_TARGET_COOKIE_SECURE=1` and requires HTTPS.

For local development, copy [`.env.example`](../.env.example) to `.env`, fill in the username and generated hash, then run `docker compose up --build`. Keep the hash inside single quotes in `.env` so Compose preserves its `$` characters. The local stack binds to `127.0.0.1:8080` and defaults to `AREA_TARGET_COOKIE_SECURE=0` for local HTTP. The optimizer has no published host port.

## Browser and native sessions

Visiting a protected page opens `/login`. After login the browser receives an HttpOnly session cookie, fetches its CSRF token from `GET /api/auth/session`, and sends `X-CSRF-Token` when uploading or logging out. The app displays the username and provides a logout button. An expired session returns the browser to login.

Sessions last 12 hours and persist across service restarts in `OUTPUT_DIR/service_auth.sqlite`; the production output volume must be retained. Only session token digests are stored. Logout revokes the current session. Changing either the configured username or password hash invalidates all existing sessions, so credential rotation requires users to log in again. Login attempts are limited per source and globally; clients cannot override the source address with `X-Forwarded-For`.

Native clients send `POST /api/auth/login` with a JSON object containing `username` and `password`. The response includes `username`, `session_token`, `csrf_token` and `expires_at`. Retain the opaque session token securely and send it as `X-Area-Target-Session` on each processing API request. The native header supplies service authentication; v1 job requests still require their existing `Authorization: Bearer <job-token>` and upload idempotency key. A service session alone does not grant access to a job. `POST /api/auth/logout` revokes the session. The browser's session endpoint omits `session_token`.

The public `/healthz` response contains only `{"status":"ok"}`. Every processing endpoint, including requirements, upload, job status and result download, requires authentication. Authentication failures use HTTP 401 with `authentication_required`; legacy API errors keep the `{error, code}` shape and v1 errors keep `{error: {code, message, retryable}}`.

## Authenticated smoke check

The smoke script reads `AREA_TARGET_USERNAME` and `AREA_TARGET_PASSWORD` from the process environment. It accepts no password command-line argument. This prompt-based launcher keeps the plaintext password out of shell history:

```bash
python - <<'PY'
import getpass
import os
import sys
from tools.deployment.smoke import main

os.environ["AREA_TARGET_USERNAME"] = input("Username: ")
os.environ["AREA_TARGET_PASSWORD"] = getpass.getpass("Password: ")
sys.argv = ["smoke.py", "--url", "https://at.3dugc.com", "--timeout", "180"]
raise SystemExit(main())
PY
```

Smoke checks `/healthz`, confirms unauthenticated legacy and v1 uploads return 401, logs in, then verifies synthetic upload, idempotent retry, processing and exact bundle size/SHA256. It carries the service session alongside each per-job Bearer token and retains the wrong-token and legacy-route isolation checks. CI generates fresh random credentials for each runtime test and removes its temporary credential files afterward.
