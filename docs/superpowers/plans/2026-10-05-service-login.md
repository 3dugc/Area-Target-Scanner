# Service Login Implementation Plan

> For agentic workers: use test-driven development and independent security review.

Goal: protect the deployed Area Target service with username/password login while preserving mobile task isolation.
Architecture: central Flask gate; SQLite sessions and attempt limits; browser Cookie/CSRF and native session header.
Tech Stack: Flask, Werkzeug scrypt, SQLite, SwiftUI, Keychain.

- [x] Create independent worktree from origin/publish; verify baseline lifecycle/mobile/smoke tests (43 passed).
- [x] Write tests/test_service_auth.py for all gate paths, missing configuration, password errors, cookie flags, CSRF, native headers, expiry, rotation, logout, login bounds and persistent attempt limits.
- [x] Run new tests and confirm missing auth implementation fails; implement web_service/auth.py and register globally in app.py.
- [x] Give existing route tests authenticated clients; verify existing per-job token failures remain enforced.
- [x] Add browser login/logout and authentication-expiry behavior; update Compose, health check, CI runtime smoke and credential documentation.
- [x] Add iOS login form, Keychain sessions and header propagation; verify native requests preserve per-job Bearer tokens.
- [x] Review diff independently, run focused/regression tests and build native client.
- [ ] Verify target deployment configuration before rollout, preserving volumes and resources. Record authenticated/anonymous live evidence.

Verification: 119 focused Python authentication, job lifecycle, mobile contract, scan safety and processing regression tests passed. Browser tested against real localhost Flask: anonymous root redirects to login, credentials sign in, account appears, logout returns to login. New Python modules pass Ruff E/F/W; both Compose manifests validate with synthetic configuration. Independent review checked central route/static gating, capability separation, concurrent login/session operations and malformed input. Docker daemon is unavailable locally; container image runtime remains a CI/deployment check. No production credential is committed; deployment is pending user credential entry and image rollout.

iOS verification in the existing working checkout: 81 tests executed, 3 intentionally skipped live opt-in tests, 0 failures. The seven authentication-related source/test files preserve the existing uncommitted mobile feature baseline and are not included in the isolated service commit. Local preview credentials were configured from the user's explicit values and verified by login, rejection of the former test account, and logout revocation. Production credentials remain outside Git.
