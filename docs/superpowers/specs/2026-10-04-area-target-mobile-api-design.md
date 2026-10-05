# Area Target mobile cloud processing design

Approved by the user on 2026-10-04: connect both the API and iOS Area Target page. The app must upload existing scan data directly, show cloud processing progress, and download durable results to the iOS device, using the same task-oriented experience as the existing Immersal mode.

## Data and workflow

The app creates an immutable, disk-backed Area Target scan ZIP from required source files (OBJ/MTL/textures, original keyframe images, manifest/poses/intrinsics). It uses native ARKit poses and does not convert data to Immersal coordinates. UV unwrap defaults on so valid untextured scan exports can be processed. The app displays preparation, upload, server processing, ready, download and saved states. A task journal and Keychain credential are persisted before submission. Foreground transfers can pause on background; accepted server jobs continue, and the app reconciles status when foregrounded/reopened. Cancellation stops the local operation and never claims to cancel accepted server processing.

Cloud processing reuses the deployed Python pipeline and its compatible companion optimizer. Results contain manifest.json, optimized.glb and features.db. Downloaded ZIPs are checked against server size/SHA256, safely unpacked into Application Support/AreaTargetCloud, and retained locally beyond server expiry. The UI supports sharing the saved ZIP and shows saved task history; original scanning/model preview and Immersal mapping remain available. Adding a new GLB renderer is outside the requested upload/download flow; local scan preview stays available.

## Versioned HTTP contract

Base URL: https://area-target.p.01xr.com

The client generates a canonical lowercase UUID job ID and a 32-byte random token encoded as 64 lowercase hexadecimal characters before the first request. The token is stored in Keychain. Only its SHA256 is stored on the server. Send it in Authorization: Bearer TOKEN for submission, status and result requests. This is task capability authorization, without adding an account system or putting a shared secret in the app.

POST /api/v1/jobs accepts multipart fields file=scan.zip, profile=fast|quality (default fast), uv_unwrap=0|1 (client default 1), and headers Idempotency-Key: UUID and Authorization: Bearer TOKEN. job_id equals Idempotency-Key, letting the client reconcile a lost response by querying the known ID. Return 202 for first accepted work, 200 for identical already accepted submissions; a changed payload/options for the same ID returns 409. A different token cannot access or overwrite an existing task. Parallel admission must preserve the worker/queue bound.

GET /api/v1/jobs/{job_id} returns the sanitized task object. GET /api/v1/jobs/{job_id}/result returns an attachment ZIP only when complete. Never expose filesystem paths, source_job_id, internal hashes, tokens, or raw stack traces. The legacy status/download/cache paths cannot reveal versioned tasks. Existing browser uploads must remain functional.

Task JSON:
```json
{"job_id":"<canonical UUID>","status":"queued|extracting|processing|completed|failed","progress":0,"stage":"queued|extracting|uv_unwrap|model_optimization|feature_extraction|packaging|completed|failed","message":"User-readable text","profile":"fast","uv_unwrap":true,"created_at":"ISO8601 UTC","finished_at":null,"expires_at":null,"error":null,"result":null}
```
Completed result JSON:
```json
{"format":"area-target-bundle","filename":"asset_bundle_UUID.zip","size_bytes":123,"sha256":"64 lowercase hex characters","url":"/api/v1/jobs/UUID/result","expires_at":"ISO8601 UTC"}
```
Failed task error and HTTP error envelope:
```json
{"error":{"code":"stable_machine_code","message":"User-readable text","retryable":false}}
```
HTTP outcomes: 400 invalid_request/invalid_archive/invalid_scan; 401 missing_or_invalid_token; 404 job_not_found (also unauthorized task to avoid existence disclosure); 409 submission_conflict/result_not_ready; 410 result_expired; 413 payload_too_large; 429 queue_full with Retry-After: 10; 500 internal_error. Known interrupted jobs use processing_interrupted and a safe resubmission action creates a new ID. Expired/no-longer-listed jobs retain their local metadata and explain that server results are no longer available.

## Resource and integrity boundaries

Request limit 512 MiB, ZIP expanded limit 500 MiB, at most 10,000 entries, bounded metadata parsing and image pixels. ZIP/manifest/poses references must resolve to regular files inside the scan directory. Require compatible scan schema or supported legacy data; accept manifest-first scans. Explicitly reject a model-only upload because feature generation needs keyframes and camera data. Result metadata describes the exact downloaded ZIP bytes; hashing is streamed. Client upload/download code uses files, not whole-archive Data. Download paths and archive extraction are contained; preserve an earlier verified result on failed retries.

## Isolation and ownership

Server implementation uses the attached managed worktree, branch codex/area-target-mobile-api. iOS uses a temporary copy of the current dirty iOS tree, with a frozen baseline. Apply only the implementation delta back to the original client tree after checking source files have not changed. Do not commit or publish unrelated pre-existing user iOS work. Publish server/API commits through develop, main and publish after each branch gate succeeds. Verify the live API with synthetic data and the real Swift client network path; no private scan is uploaded without user selection.

## Acceptance evidence

1. API tests prove creation, auth/legacy isolation, idempotency/reconciliation, status/expiry/result metadata, upload/resource/path validation and atomic capacity admission.
2. Swift tests prove disk-backed request formation, error/status decoding, persistent task recovery, safe asset validation, upload-to-download state transitions, cancellation and platform separation.
3. Build and run the iOS test target on an available simulator; host/render the Area Target UI and capture upload/ready/saved states.
4. Run a synthetic scan through the actual live versioned API after publishing, using the Swift client where feasible, and validate the downloaded GLB and SQLite feature database.
5. Apply the verified client delta to the user's current iOS workspace and build that workspace. Preserve unrelated modifications.
