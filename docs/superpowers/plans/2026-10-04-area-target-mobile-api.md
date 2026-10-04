# Area Target mobile cloud processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Connect the iOS Area Target page to the deployed cloud service for direct scan upload, task tracking and local asset download.

**Architecture:** A versioned, token-protected idempotent job API wraps the existing pipeline. A dedicated Swift API/archive/asset layer and processing model feed a platform-specific SwiftUI page. Immutable disk files and an atomic task journal support interrupted request reconciliation and safe local persistence.

**Tech Stack:** Flask, SQLite, pytest, Swift Foundation URLSession, Keychain, CryptoKit, ZIPFoundation, SwiftUI and XCTest.

## Task 1: Versioned API and processing input boundary

Files: web_service/app.py; new web_service/mobile_api.py if separation helps; tests/test_mobile_api.py; input-validation tests; docs/area-target-api.md; API OpenAPI JSON; .github/workflows/deploy.yml relevant test selection.

- [ ] Write pytest cases against POST /api/v1/jobs with the approved headers, GET status/result, explicit error envelopes and legacy isolation. Run them and record expected 404 failures before implementation.
```python
response = client.post('/api/v1/jobs', headers={'Authorization': 'Bearer ' + 'a'*64, 'Idempotency-Key': '4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1'}, data={'file': (scan_zip, 'scan.zip'), 'uv_unwrap':'1', 'profile':'fast'})
assert response.status_code == 202
assert response.get_json()['job_id'] == '4f619a9c-19cd-45d2-bfd7-c2f82ba5cfa1'
```
- [ ] Implement the approved contract, token-hash persistence, response DTO, identical-retry reconciliation and queue locking. Ensure legacy paths reject protected jobs and cannot reuse protected results.
- [ ] Add input containment/limits and manifest-first/untextured support tests before changing validation. Run mobile API and existing durable orchestration/input/native pipeline tests.
- [ ] Add API docs/OpenAPI with literal request/response examples from the design. Update image smoke to cover v1 auth and protected download while retaining browser compatibility evidence.

## Task 2: Swift transport, scan archive and verified asset persistence

Files: new ios_scanner/AreaTargetScanner/Services/AreaTargetAPIClient.swift, AreaTargetScanArchive.swift, AreaTargetAssetStore.swift; new client tests. This task owns these files only.

- [ ] Write URLProtocol/request tests and ZIP validation tests first. A test must assert the multipart payload is a file, the endpoint is the fixed HTTPS host, UUID/token headers are preserved and retries reuse the same identity. Run and record missing-type/behavior failures.
- [ ] Define protocol AreaTargetAPI with submit(archiveURL:jobID:token:profile:uvUnwrap:progress:), status(jobID:token:), and download(jobID:token:result:progress:), returning Codable task/result objects matching the design's exact snake_case fields. Use disk-backed upload/download, redirect rejection and bounded response parsing.
- [ ] Build an immutable white-listed scan archive from current source files; validate required geometry/frame data and hash/copy while checking cancellation. Do not reuse a possibly stale share ZIP.
- [ ] Implement streamed SHA256/size check and bounded safe ZIP extraction. Validate asset manifest references and GLB/SQLite presence. Atomically publish to the per-job local directory, with saved bundle URL plus asset URLs, preserving earlier good results on failure.
- [ ] Run the transport/archive/asset XCTest group and report exact public type signatures to the processing-model worker.

## Task 3: Swift task journal, state machine and Area Target page

Files: new AreaTargetProcessingJob.swift, AreaTargetJobStore.swift, AreaTargetProcessingModel.swift, AreaTargetProcessingView.swift; modifications ContentView.swift, ScanProcessingView.swift, ScannerWorkspace.swift; corresponding model/UI tests. This task owns these files only; controller owns project.pbxproj registration and any ScanViewModel integration edits.

- [ ] Write fake API task-state tests first for prepare/upload/process/ready/download/saved, lost-submit response recovery, foreground restoration, store failures, local pause/cancellation and deletion protection.
- [ ] Implement an atomic journal (no tokens), dedicated Keychain tokens persisted before network operations, a single local active transfer guard and frontmost polling. No accepted cloud cancellation is implied. Preserve source records and old good assets.
- [ ] Add the Area Target task UI with upload progress, cloud stages, download progress, saved state, share result and task history. Keep original scan preview and independent Immersal behavior. Route per platform, do not simply toggle the existing Immersal cloud boolean.
- [ ] Register task lifecycle/operation guards for app background/foreground and scan deletion. Verify restart/status reconciliation does not create duplicate cloud jobs.
- [ ] Run new XCTest state and UI tests and capture a hosted Area Target page for upload/ready/saved states.

## Task 4: Integration, publication and live proof

- [ ] Register all new source/tests in project.pbxproj, independently review spec coverage then code quality, and fix failures with regression tests.
- [ ] Run full relevant pytest and iOS XCTest/build. Run the existing texture/native helper and synthetic upload/processing/download integration using the new API.
- [ ] Commit only API/server changes and docs in the managed server tree. Push develop and await both CI and image publish success, then merge the same content to main and publish with fresh gates.
- [ ] Update Portainer to pull verified publish images. Use the real Swift network client with synthetic scan data against live HTTPS and confirm local saved assets, GLB and SQLite contents. Capture the browser/hosted app result.
- [ ] Compare original iOS files with the frozen baseline. Apply only files changed by this task, preserving unrelated user work, then build original workspace and run its appropriate tests.
- [ ] Audit every acceptance item and report API/CI endpoints, iOS user flow, actual verification, and any concrete limits. Clean generated promotion worktrees and temporary running servers.
