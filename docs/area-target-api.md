# Area Target mobile processing API

Base URL: `https://area-target.p.01xr.com`. Machine-readable documentation is available at `GET /api/v1/openapi.json`.

Create an immutable scan ZIP on disk. Before sending it, generate a canonical lowercase UUID and a random 32-byte token encoded as 64 lowercase hex characters. Persist the UUID, processing options, and archive identity in the task journal and the token in Keychain. The server stores only the token's SHA256. The UUID is the `job_id`, so a client can reconcile an upload whose response was lost.

```sh
JOB_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
TASK_TOKEN=$(openssl rand -hex 32)
curl --fail-with-body https://area-target.p.01xr.com/api/v1/jobs \
  -H "Idempotency-Key: $JOB_ID" \
  -H "Authorization: Bearer $TASK_TOKEN" \
  -F 'file=@scan.zip;type=application/zip' \
  -F 'profile=fast' -F 'uv_unwrap=1'
```

`POST /api/v1/jobs` accepts one multipart file named `file`, `profile=fast|quality` (default `fast`), and `uv_unwrap=0|1` (default `1`). A new job returns **202**. An identical archive and identical options under the same UUID and token returns **200**, including after completion or restart. Different bytes or options for an existing UUID return **409 submission_conflict**. A retry never creates a second processing task. Use a new UUID and token when intentionally starting another job.

The submission and status response use the same public task shape:

```json
{
  "job_id": "4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1",
  "status": "queued",
  "progress": 0,
  "stage": "queued",
  "message": "Waiting for processing.",
  "profile": "fast",
  "uv_unwrap": true,
  "created_at": "2026-10-04T02:00:00+00:00",
  "finished_at": null,
  "expires_at": null,
  "error": null,
  "result": null
}
```

Poll `GET /api/v1/jobs/{job_id}` with `Authorization: Bearer TOKEN`. Status is `queued`, `extracting`, `processing`, `completed`, or `failed`; progress is an integer from 0 to 100. Stage is `queued`, `extracting`, `uv_unwrap`, `model_optimization`, `feature_extraction`, `packaging`, `completed`, or `failed`. Display the message as explanatory text; use the stable enums for app state.

```sh
curl --fail-with-body "https://area-target.p.01xr.com/api/v1/jobs/$JOB_ID" \
  -H "Authorization: Bearer $TASK_TOKEN"
```

A completed task contains this result object. The SHA256 and byte count describe the exact ZIP downloaded from its relative URL; they are computed once while publishing the bundle and persisted in SQLite.

```json
{
  "format": "area-target-bundle",
  "filename": "asset_bundle_4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1.zip",
  "size_bytes": 123456,
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "url": "/api/v1/jobs/4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1/result",
  "expires_at": "2026-10-05T02:01:00+00:00"
}
```

Download `GET /api/v1/jobs/{job_id}/result` with the same token to a file, verify its byte count and streamed SHA256, and unpack it with contained paths and bounded expanded size. Result ZIPs are bounded to 512 MiB. The bundle contains `manifest.json`, `optimized.glb`, and `features.db`. Save verified assets in Application Support; local assets can remain available after the server expires its copy.

```sh
curl --fail-with-body "https://area-target.p.01xr.com/api/v1/jobs/$JOB_ID/result" \
  -H "Authorization: Bearer $TASK_TOKEN" -o area-target-bundle.zip
```

The default completed-job retention is 24 hours after completion, and failed-job metadata is retained for 6 hours; operators can configure these durations. `expires_at` is authoritative. An existing expired or missing bundle returns **410**. Once periodic cleanup removes the record, the task returns **404**. Task requests and results use `Cache-Control: no-store`.

If the server restarts, interrupted queued/extracting/processing jobs become failed with `processing_interrupted`; the UUID and capability hash survive. Reconcile the original UUID first, then offer a new task with a new UUID. Backgrounding or cancelling a local transfer does not cancel already accepted server processing.

All HTTP errors and failed task `error` objects use:

```json
{"error":{"code":"queue_full","message":"The processing queue is full. Try again shortly.","retryable":true}}
```

| HTTP | Codes | Client action |
|---|---|---|
| 400 | `invalid_request`, `invalid_archive`, `invalid_scan` | Correct the scan or request. |
| 401 | `missing_or_invalid_token` | Load the saved task token. |
| 404 | `job_not_found` | Task missing or capability does not match; preserve local history. |
| 409 | `submission_conflict`, `result_not_ready` | Keep the original identity/options, or continue polling. |
| 410 | `result_expired` | Preserve previously verified local assets. |
| 413 | `payload_too_large` | Reduce the upload; the full multipart request limit is 512 MiB. |
| 429 | `queue_full` | Honor `Retry-After: 10`; retry the same submission identity. |
| 500 | `internal_error` | Query the known UUID before retrying the upload. |

Missing or malformed tokens return 401. A validly formed wrong token returns 404, including on submission, so task existence is not disclosed. Protected tasks cannot be read through legacy `/api/status/{id}` or `/api/download/{id}`, and their results cannot seed the public browser cache. The browser upload flow remains available independently.

The archive must contain a regular, nonempty `model.obj` and either a schema-v1 ARKit `manifest.json` or legacy `poses.json` with keyframe references and camera intrinsics. Manifest-first scans are supported. Schema-v1 fields are `schemaVersion=1`, `coordinateSystem=arkit-world`, `matrixLayout=arkit-column-major`, `units=meters`, and frame `imageFile`, 16-value finite affine `transform`, `imageOrientation`, `image.width/height`, and `intrinsics.fx/fy/cx/cy`. Legacy scans use ARKit column-major transforms and `intrinsics.json` or per-frame intrinsics. Model-only uploads are rejected. With UV unwrap enabled, an untextured OBJ is supported; otherwise `model.mtl` and `texture.jpg` are required.

ZIPs are bounded to 500 MiB expanded and 10,000 entries. Metadata JSON files are bounded to 8 MiB, frames to 10,000, each image to 32 million pixels with a maximum dimension of 8,192, with no aggregate pixel rejection at raw admission. Processing derivatives are bounded to 200 million pixels. Images must be valid and metadata dimensions must match. Absolute/traversing/duplicate ZIP paths, symlinks, special files, encrypted entries, and references outside the scan directory are rejected. OBJ/MTL external resources must also remain inside the scan directory.

The production service uses one Gunicorn process owning the executor and cleanup thread; SQLite admission reserves the combined worker/queue capacity transactionally. Keep that single-process deployment topology so startup interruption recovery has one owner.

Run `python tools/deployment/smoke.py --url https://area-target.p.01xr.com --timeout 180` to upload only generated synthetic data, poll, verify capability and legacy isolation, download, and validate exact ZIP metadata, GLB, and SQLite features. No private scan files are read by the smoke script.

## Versioned scan preparation

`GET /api/v1/processing-requirements` is public and returns schema version 1, policy `mobile-scan-preparation-v1`, policy version 1, per-profile processing budgets and archive safety limits. Both mobile profiles currently prepare at most 80 frames, a maximum image long edge of 1,600 pixels, and at most 200 million total processed pixels. These are processing budgets rather than a 72-frame capture limit.

iOS fetches the requirements before a new upload. For a recognized policy, it creates a separate ZIP using uniformly spaced frames including the first and last. It applies a common scale constrained by both the long edge and actual pixel total; it then uses each image's final integer dimensions to scale `fx/cx` and `fy/cy`. Camera poses and pixel orientation are preserved. The full original capture remains available and its local source fingerprint is unchanged. Unknown, invalid or unavailable requirements fall back to the full original ZIP, with server-side preparation. Task retries reuse the exact stored ZIP and submission identity.

The client ZIP manifest records `clientPreparation` with the policy/version, original and selected frame counts, selected indices, actual processed pixels, resize count, maximum output dimension and a scale digest. This is client-reported provenance, not a trusted resource-budget bypass. The server validates actual images and metadata, then creates its own derivative work directory. `scanPreparation` in the result manifest records the actual server input and preparation, while `clientPreparation` remains separately labeled. An already prepared upload avoids repeat image resizing; oversized raw uploads are prepared on the server.

Mobile `quality` keeps ORB 2,000 features per frame, vocabulary up to 1,000, and caps AKAZE to 500 per frame. Together with 80 frames this bounds the database to 200,000 features and the ORB vocabulary comparisons to 160 million. The original CLI quality behavior is independent of this mobile constraint.

Area Target and Immersal comparisons retain the same original scan identity and the same evaluation frames. Their training preparation may differ; preparation provenance and the frozen result ZIP digest distinguish builds. This comparison does not imply identical training image sets.

For a real oversized synthetic scan regression, run `python tools/deployment/smoke.py --url https://area-target.p.01xr.com --large-scan --timeout 900`. It submits 100 original 1920×1440 images (276,480,000 pixels), then verifies a downloadable bounded result and coverage of the full sequence. No private camera data is used.
