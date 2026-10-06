# Area Target mobile processing API

Base URL: `https://at.3dugc.com`; `https://area-target.p.01xr.com` is the legacy server. Machine-readable documentation is available at `GET /api/v1/openapi.json`.

Sign in using `POST /api/auth/login` with JSON `username` and `password`. Save only the returned `session_token` and expiry in Keychain. Every subsequent request, including processing requirements and OpenAPI, sends `X-Area-Target-Session: SESSION_TOKEN`. The session expires after 12 hours, is revoked by `POST /api/auth/logout`, and is separate from the task token below. See [service login setup](service-login.md).

Create an immutable scan ZIP on disk. Before sending it, generate a canonical lowercase UUID and a random 32-byte token encoded as 64 lowercase hex characters. Persist the UUID, processing options, and archive identity in the task journal and the token in Keychain. The server stores only the token's SHA256. The UUID is the `job_id`, so a client can reconcile an upload whose response was lost.

```sh
JOB_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
TASK_TOKEN=$(openssl rand -hex 32)
curl --fail-with-body https://at.3dugc.com/api/v1/jobs \
  -H "Idempotency-Key: $JOB_ID" \
  -H "X-Area-Target-Session: $SESSION_TOKEN" \
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

Poll `GET /api/v1/jobs/{job_id}` with both `X-Area-Target-Session: SESSION_TOKEN` and `Authorization: Bearer TOKEN`. Status is `queued`, `extracting`, `processing`, `completed`, or `failed`; progress is an integer from 0 to 100. Stage is `queued`, `extracting`, `uv_unwrap`, `model_optimization`, `feature_extraction`, `packaging`, `completed`, or `failed`. Display the message as explanatory text; use the stable enums for app state.

```sh
curl --fail-with-body "https://at.3dugc.com/api/v1/jobs/$JOB_ID" \
  -H "X-Area-Target-Session: $SESSION_TOKEN" \
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
curl --fail-with-body "https://at.3dugc.com/api/v1/jobs/$JOB_ID/result" \
  -H "X-Area-Target-Session: $SESSION_TOKEN" \
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
| 401 | `authentication_required` | Sign in again; preserve the saved task UUID/token. |
| 401 | `missing_or_invalid_token` | Load the saved task token. |
| 404 | `job_not_found` | Task missing or capability does not match; preserve local history. |
| 409 | `submission_conflict`, `result_not_ready` | Keep the original identity/options, or continue polling. |
| 410 | `result_expired` | Preserve previously verified local assets. |
| 413 | `payload_too_large` | Reduce the upload; the full multipart request limit is 512 MiB. |
| 429 | `queue_full` | Honor `Retry-After: 10`; retry the same submission identity. |
| 500 | `internal_error` | Query the known UUID before retrying the upload. |

Missing or malformed tokens return 401. A validly formed wrong token returns 404, including on submission, so task existence is not disclosed. Protected tasks cannot be read through legacy `/api/status/{id}` or `/api/download/{id}`, and their results cannot seed the public browser cache. The browser upload flow also requires service login; cookie-authenticated mutations require its separate CSRF token.

The archive must contain a regular, nonempty `model.obj` and either a schema-v1 ARKit `manifest.json` or legacy `poses.json` with keyframe references and camera intrinsics. Manifest-first scans are supported. Schema-v1 fields are `schemaVersion=1`, `coordinateSystem=arkit-world`, `matrixLayout=arkit-column-major`, `units=meters`, and frame `imageFile`, 16-value finite affine `transform`, `imageOrientation`, `image.width/height`, and `intrinsics.fx/fy/cx/cy`. Legacy scans use ARKit column-major transforms and `intrinsics.json` or per-frame intrinsics. Model-only uploads are rejected. With UV unwrap enabled, an untextured OBJ is supported; otherwise `model.mtl` and `texture.jpg` are required.

ZIPs are bounded to 500 MiB expanded and 10,000 entries. Metadata JSON files are bounded to 8 MiB, frames to 10,000, each image to 32 million pixels with a maximum dimension of 8,192, with no aggregate pixel rejection at raw admission. Processing derivatives are bounded to 200 million pixels. Images must be valid and metadata dimensions must match. Absolute/traversing/duplicate ZIP paths, symlinks, special files, encrypted entries, and references outside the scan directory are rejected. OBJ/MTL external resources must also remain inside the scan directory.

The production service uses one Gunicorn process owning the executor and cleanup thread; SQLite admission reserves the combined worker/queue capacity transactionally. Keep that single-process deployment topology so startup interruption recovery has one owner.

Run `python tools/deployment/smoke.py --url https://area-target.p.01xr.com --timeout 180` to upload only generated synthetic data, poll, verify capability and legacy isolation, download, and validate exact ZIP metadata, GLB, and SQLite features. No private scan files are read by the smoke script.

## Versioned scan preparation

`GET /api/v1/processing-requirements` requires service login. The queryless endpoint retains schema version 1, policy `mobile-scan-preparation-v1`, policy version 1 and the existing 80-frame / 1,600-long-edge / 200-million-pixel mobile budgets. New clients explicitly request `?policy=mobile-scan-preparation-v2`; unknown policies return HTTP 400 `unsupported_preparation_policy`. The scan manifest schema remains version 1.

V2 advertises `capacityTier: 100` by default, with `maxFrames: 100`, `maximumTotalPixels: 200000000`, `maximumLongEdge: 1600` and `minimumLongEdge: 1024` for both profiles. The explicit deployment setting `AREA_TARGET_PREPARATION_TIER=500` advertises 500 frames and 600000000 pixels. Enable 500 only after target deployment and independent localization acceptance; local synthetic capacity tests are not recognition-quality evidence. ZIP bytes, expanded bytes, per-image limits and path checks are unchanged. Uploaders cannot supply arbitrary processing budgets.

iOS creates an independent upload ZIP containing **all** source frames for v2. It limits long edge and encoded archive bytes, preserving each source's smaller-than-1024 dimensions. It does not apply the final processing frame/pixel limits before server deduplication. If encoded bytes cannot fit without violating the minimum resolution, preparation fails rather than deleting views. For every resized image, actual integer width and height separately scale `fx/cx` and `fy/cy`. Pose, orientation, source IDs and timestamps are preserved; derivative camera filenames cannot overwrite shared material images. The original capture and its source fingerprint remain unchanged. Task retries reuse the exact stored ZIP, policy and identity.

V2 `clientPreparation` retains the v1 provenance fields and adds `receivedFrameCount`, `capacityTier`, `selectionVersion: upload-all-v2` and `selectionDigest`. Original, received and selected client counts equal the actual uploaded frame count; selected indices are the complete ordinal range. The digest is SHA-256 of compact, sorted-key UTF-8 JSON containing exactly `capacityTier`, `policy`, `selectedIndices` and `selectionVersion`. The server independently verifies actual dimensions, source decode work (≤2 billion pixels), provenance and the deployment tier. V1 archives and raw uploads without v2 provenance continue using v1.

V2 requirements optionally advertise `criticalFrameProtection` with exactly `version: critical-frame-protection-v1`, `riskVersion: gray-quality-risk-v1`, `maximumProtectedFrames: 8`, `maximumProtectedLongEdge: 1920`, `sharpnessThreshold: 16` and `contrastThreshold: 20`. Clients use protection only after validating this capability. Ordinary frames retain the 1600-long-edge limit; up to eight protected frames may retain a long edge up to 1920, without enlarging smaller sources. The optional v2 `clientPreparation.criticalFrameProtection` contains exactly `version`, `riskVersion`, `protectedIndices` and `candidateFrameCount`. Indices are sorted, unique source ordinals in the uploaded frame list, at most eight; the candidate count is an integer between the protection count and the source frame count. Unknown versions, fields, malformed counts and high-resolution frames outside those indices are rejected using actual per-frame raster dimensions. V1 and v2 archives without the extension preserve their existing behavior.

The `gray-quality-risk-v1` proxy uses the existing native gray-quality metrics on a stored-orientation grayscale raster with long edge at most 1920. A quality rejection, Laplacian variance ≤16 or grayscale standard deviation ≤20 marks a candidate. Quality-rejected candidates rank first, followed by increasing Laplacian variance and stable source ordinal; the first eight receive protection. These two-dimensional metrics cannot predict the separate minimum of 20 valid three-dimensional feature correspondences. No source view is deleted based on this proxy. A saved upload's protection provenance is part of its ZIP bytes and submission identity; retries reuse the exact saved ZIP.

After authoritative deduplication, the server fixes still-retained protected frames at their received dimensions up to 1920 and distributes the remaining 200M/600M pixel budget among ordinary frames, with the existing 1600 cap and 1024 floor. It neither silently shrinks protected frames nor drops a view to pass a budget. If protected sizes plus ordinary minimum sizes cannot fit, preparation fails with `coverage_budget_exceeded`. The upload-side source analysis limit remains 2B pixels, so protection does not impose a new uploaded-frame-count ≤ capacity-tier rule. Result `scanPreparation.criticalFrameProtection` records the version, risk version, candidate count, requested protected source ordinals, actually retained protected ordinals and protection removed by deduplication; actual image sizes remain authoritative per frame.

The authoritative server selection (`pose-visual-dedup-v1`) requires near translation (≤8 cm), full rotation (≤5°), the same tracking run and highly matching visual geometry. It analyzes 320-long-edge thumbnails with a strictly enforced 500-point ORB bound, uses at most 32 representative comparisons per frame and keeps uncertain/weak views. ORB matches require mutual ratio matching, ≥50 homography inliers, ≥90% inlier ratio, ≥85% matching detected features in **both** images, and ≥9 occupied cells in both 4×4 grids. A full-thumbnail check additionally requires ≥90% homography footprint overlap in both views and normalized grayscale correlation ≥0.97, so shared textured patches cannot hide changed weak-texture regions. Thresholds are initial engineering values requiring independent counterexample calibration. Duplicate chains cannot delete unique endpoints. Quality ranks exposure validity, Laplacian sharpness, feature count and stable ordinal order.

After deduplication, all distinct views share the actual pixel budget with a 1024-long-edge floor (smaller originals are neither enlarged nor further reduced). `coverage_budget_exceeded` explicitly fails instead of recapping to 80. Failed task errors can contain numeric `details` with original/received/duplicate/selected counts, maximum frames/pixels and minimum resolution. The result's `scanPreparation` records those counts, `duplicateGroups`, `selectedIndices`, capacity, actual pixels and selection/scale digests; separately labeled `clientPreparation` survives. `sourceKeyframeSelection` reports possible weak views. UV operates on at most 4096 faces per assignment batch with the existing 64 MiB decoded-image cache.

V2 feature extraction accepts the server's prepared selection without another 80-frame sample. Detection retains the existing per-frame limits. After geometry hits, quality balances ≤160000 ORB plus ≤40000 AKAZE; fast balances ≤200000 ORB and no AKAZE. Each eligible view reserves at least 20 ORB, and unused quota is redistributed before vocabulary/BoW training. The bundle reports actual retained and insufficient-feature frames. The reader's 1000-frame, 200000-feature and 200-million ORB×vocabulary limits remain unchanged. V1 and CLI feature selection retain their existing behavior.

Area Target and Immersal comparisons retain the same original scan identity and the same evaluation frames. Their training preparation may differ; preparation provenance and the frozen result ZIP digest distinguish builds. This comparison does not imply identical training image sets.

For a real oversized synthetic scan regression, run `python tools/deployment/smoke.py --url https://area-target.p.01xr.com --large-scan --timeout 900`. It submits 100 original 1920×1440 images (276,480,000 pixels), then verifies a downloadable bounded result and coverage of the full sequence. No private camera data is used.
