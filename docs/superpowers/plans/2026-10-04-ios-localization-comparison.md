# iOS Localization and Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Connect the real Area Target spatial recognition engine to iOS and provide localization tests, transparent performance scores, and same-scan/same-query comparison with Immersal.

**Architecture:** Use separate serial native adapters for each engine, a shared evaluation model, and a bounded recorder/replay coordinator. Keep OpenCV private to a separate Area Target framework because Immersal already includes OpenCV symbols. Bind assets to the same source scan, convert both results to original scan coordinates, and exclude calibration frames from cold-start evaluation.

**Tech Stack:** Swift, ARKit, SceneKit, SQLite3, C++17, OpenCV 4.10, existing Immersal SDK, XCTest, Apple Clang/Xcode.

---

Implementation workspace: `/Users/dirui/.codex/worktrees/area-target-deployment/Area-Target-Scanner`, branch `codex/ios-localization-comparison`. It contains a frozen copy of the current working iOS application. Baseline: `/private/tmp/area-target-ios-localization-20261004/baseline/ios_scanner`; hashes: `/private/tmp/area-target-ios-localization-20261004/baseline-sha256.json`. Only task deltas may be applied back to `/Users/dirui/Documents/Area-Target-Scanner`. Existing uncommitted Immersal/UI work must not be staged as this task's release.

The user has authorized implementation in the current session. Execute with focused subagents and independent review; no further execution-mode question is necessary. Native build and pure evaluation work can proceed independently with disjoint file ownership; root owns project registration and final integration.

## Task 1: Real Area Target native boundary

Files to create:
- `ios_scanner/AreaTargetScanner/Services/AreaTargetFeatureDatabase.swift`
- `ios_scanner/AreaTargetScanner/Services/AreaTargetOfflineLocalizer.swift`
- `ios_scanner/AreaTargetScanner/ThirdParty/AreaTargetNative/AreaTargetNative.h`
- `tools/ios/build_area_target_native.py`
- `tools/ios/verify_area_target_native.py`
- `ios_scanner/AreaTargetScannerTests/AreaTargetFeatureDatabaseTests.swift`
- `ios_scanner/AreaTargetScannerTests/AreaTargetOfflineLocalizerTests.swift`

Root later modifies `AreaTargetScanner-Bridging-Header.h` and `AreaTargetScanner.xcodeproj/project.pbxproj` to register/embed the produced framework. Do not change the Unity native artifact or copy the old stub into the application.

- [x] Write a failing build/link gate that checks a framework exposing `vl_*`, no public `cv::*` exports, successful load/add/build/process/destroy symbol coverage, and composite link with the existing `libPosePlugin.a`. Use Apple Clang and existing C API, then run the gate against the current app and observe the missing native integration.
- [x] Download the official pinned OpenCV framework to a task cache; verify the download, inspect slices/platform, build the existing three real native sources into a private dynamic framework, and export only the C boundary. Device arm64 is required. If the official framework has no Apple Silicon simulator slice, build a matching simulator OpenCV slice from official source or explicitly document a device-only boundary while still testing the real native algorithm on macOS; never substitute a LOST stub.
- [x] Run the composite link/symbol gate and the known-pose real native fixture. Keep the two OpenCV implementations isolated; verify the framework does not resolve its OpenCV calls against Immersal's definitions.
- [x] Write database rejection and loading-order tests before implementing the reader. Construct real SQLite fixtures with the production schema, then assert invalid BLOBs, non-finite points, orphan features, empty data, missing tables, corrupt databases, and resource excesses are rejected.

The actual SQL inputs are:

```sql
SELECT word_id, descriptor, idf_weight FROM vocabulary ORDER BY word_id;
SELECT id, pose FROM keyframes ORDER BY id;
SELECT x, y, x3d, y3d, z3d, descriptor FROM features WHERE keyframe_id=? ORDER BY id;
SELECT x, y, x3d, y3d, z3d, descriptor FROM akaze_features WHERE keyframe_id=? ORDER BY id;
```

`pose` contains 16 row-major float64 values (128 bytes); ORB descriptors are 32 bytes; optional AKAZE descriptors are 61 bytes. Open read-only, require ordinary tables, bound file/BLOB/row sizes and SQLite execution, and load vocabulary → keyframes → optional AKAZE → build index. Initial resource budgets: at most 1,000 keyframes, 200,000 total features, 4,096 vocabulary words; reject before unbounded allocation. SQLite errors are converted to a fixed localized error, without raw paths.

Native adapter contract:

```swift
struct AreaTargetLocalizationResult {
    let cameraFromScan: simd_float4x4
    let confidence: Float
    let matchedFeatures: Int
}
protocol AreaTargetOfflineLocalizing: AnyObject {
    func load(url: URL) async throws -> Int
    func localize(pixels: Data, width: Int, height: Int,
                  intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult?
    func close()
}
```

- [x] Implement the adapter on its own serial queue. Validate dense Gray8 length and finite positive focal lengths. Call `vl_process_frame_out` with `has_unity_world_from_camera=0`; ARKit tracking poses are evaluation references, not an additional inference input.
- [x] Test the pose contract using a non-identity rotation/translation: reconstruct the row-major matrix and assert `worldFromScan = worldFromCamera * cameraFromScan`. Do not flip axes or take the inverse a second time.
- [x] Run reader/adapter tests, real native fixture, link gate, and self-review. Return exact file list and logs; do not edit project registration or root user files.

## Task 2: Common evaluation and versioned score

Files to create:
- `ios_scanner/AreaTargetScanner/Services/LocalizationEvaluation.swift`
- `ios_scanner/AreaTargetScannerTests/LocalizationEvaluationTests.swift`

Provide pure Foundation/simd types, independent of SDK linkage. Reports are Codable and identify provider, asset, scan fingerprint, score version, timing mode, threshold values, sample counts, capture span, tracked distance, success rate, first recognition timing, latency percentiles, and alignment-change percentiles. Use a `LocalizationEvaluationAccumulator` fed by immutable frame identity, timestamp, AR camera position, measured algorithm latency and optional `worldFromScan`.

- [x] Write failing tests for all-success, all-failure, non-finite pose, missing samples, invalid timing, percentile interpolation, common-origin invariance, and exact score weighting.

The weighting test uses measured values at baseline thresholds:

```swift
// 80% success and all three P95 values at threshold:
// 40 * 0.8 + 20 + 20 + 20 == 92.
XCTAssertEqual(report.score, 92)
```

- [x] Implement the pure accumulator and score. Score formula version 1:

```text
score = round(40*successRate
              +20*min(1,3/p95LatencySeconds)
              +20*min(1,0.25/p95TranslationDeltaMeters)
              +20*min(1,5/p95RotationDeltaDegrees))
```

Zero measured values earn full points for that component. At least 20 common valid attempts, 30 seconds of uninterrupted capture and 3 meters of valid AR tracked travel are required; at least two successful poses and common-coordinate calibration are required for a nonzero complete score. With adequate common capture and no successful recognition, show score 0. Otherwise missing evidence produces no total score and an explicit reason. No vendor confidence is used.

- [x] Count failed localization calls in the denominator and latency statistics. Tracked distance uses the common captured camera sequence, not only successful matches. Record capture-offset first recognition separately from cumulative replay computation time. Percentiles use the current linear interpolation rule.
- [x] Preserve fixed localized summaries, recommendations and explicit metric limitations. Scores are empirical screening, not absolute accuracy. Run tests with a small macOS SwiftPM harness and iOS XCTest after project registration; keep artifacts isolated.
- [x] Independent spec review followed by code-quality review; address findings before integration.

## Task 3: Asset identity and bounded comparison coordinator

Files to create:
- `ios_scanner/AreaTargetScanner/Services/ScanSourceFingerprint.swift`
- `ios_scanner/AreaTargetScanner/Services/LocalizationReportStore.swift`
- `ios_scanner/AreaTargetScanner/Services/LocalizationComparison.swift`
- `ios_scanner/AreaTargetScannerTests/ScanSourceFingerprintTests.swift`
- `ios_scanner/AreaTargetScannerTests/LocalizationComparisonTests.swift`
- `ios_scanner/AreaTargetScannerTests/LocalizationReportStoreTests.swift`

Modify only task deltas in `Models/AreaTargetProcessingJob.swift`, `Models/ImmersalMappingJob.swift`, `Services/AreaTargetProcessingModel.swift`, `Services/ImmersalMappingModel.swift` to persist a common optional source fingerprint alongside each frozen submission. Old Codable records remain readable and are labeled as unknown provenance rather than automatically eligible.

- [x] Write fingerprint tests proving source path/name changes do not change a fingerprint, image/model bytes do change it, unsafe metadata paths are rejected, and the fingerprint remains independent of the two ZIP/export formats.
- [x] Compute SHA256 over canonical scan metadata and referenced source image/model bytes in bounded streaming reads. Freeze the fingerprint with upload preparation, and prevent a changed source from being paired with an existing different-version asset.
- [x] Write coordinator tests with two fake native boundaries which log frame ID/pixel digest/intrinsics. Assert exact input equality, identical eligible frame denominator, preserved failures, bounded capture and cancellation, and new generations rejecting stale callbacks.
- [x] Implement frozen query frames: sequence ID, timestamp, dense Gray8 pixels, size, intrinsics and captured AR pose. Accept only normal uninterrupted tracking. Use at most 32 frames, 96 MiB pixels, 1.5-second sampling interval and a 1920-pixel long edge; if resizing, use identical pixels and rescaled intrinsics for both engines.
- [x] Prepare Immersal mapFromScan using existing robust alignment. Exclude training/calibration frames from reports, then reload engines before replay. Area Target has identity mapFromScan. If common alignment fails, retain raw success/latency fields but suppress a complete nonzero score and any fairness claim.
- [x] Replay all accepted frozen frames sequentially to each engine, measuring only its own call duration. Preserve continuous within-run state, reset between runs, and record engine version/configuration, execution order and timing semantics.
- [x] Write report persistence tests for bounded JSON, atomic saves, corruption isolation, schema/backward compatibility and export content excluding images/tokens/GPS. Save complete reports without depending on cloud retention.

## Task 4: iOS localization workflow and comparison UI

Files to create:
- `ios_scanner/AreaTargetScanner/Services/AreaTargetLocalizationSession.swift`
- `ios_scanner/AreaTargetScanner/Views/AreaTargetMapTestView.swift`
- `ios_scanner/AreaTargetScanner/Views/LocalizationEvaluationView.swift`
- `ios_scanner/AreaTargetScanner/Views/LocalizationComparisonView.swift`
- `ios_scanner/AreaTargetScannerTests/AreaTargetLocalizationSessionTests.swift`
- `ios_scanner/AreaTargetScannerTests/LocalizationWorkflowTests.swift`
- `ios_scanner/AreaTargetScannerTests/LocalizationRenderTests.swift`

Root owns changes to `ContentView.swift`, `Views/AreaTargetProcessingView.swift`, `Views/ImmersalMapTestView.swift`, `Services/ImmersalLocalizationSession.swift`, `Models/ScannerWorkspace.swift`, bridging header, project.pbxproj and shared schemes.

- [x] Write failing lifecycle/navigation tests: downloaded Area Target assets offer localization; camera permission/loading/cancel/background/tracking reset cannot leave engines running; an existing Immersal workflow keeps its download/export behavior.
- [x] Connect the real Area Target adapter to ARSession and existing grayscale packing. Reuse original scan mesh/marker preview without introducing a GLB renderer. Compose native pose exactly once into AR world; native calls remain off main thread.
- [x] Add shared metric/score views and report export to both providers. Keep old Immersal reports readable and their metric meanings explicit.
- [x] Add a same-scan comparison entry, required asset/provenance checks, bounded capture progress, sequential replay progress and side-by-side results. Sample/calibration failures show explanations rather than invented scores.
- [x] Register/embed the private native framework, new Swift files and tests. Build simulator and generic device targets. Run rendering tests in light/dark/large text; save proof images from actual native UI.

## Task 5: Final review, apply and verification

- [x] Review spec coverage before code quality. Verify the real Area Target path reaches native processing, no stub fallback, no second axis conversion, no training frames in results, and no scoring unsupported evidence.
- [x] Compare frozen baseline hashes and apply only reviewed task deltas back to the original project. Preserve unrelated dirty files and SDK assets. Do not broadly stage the copied pre-existing working iOS code.
- [x] Run original iOS full regression:

```bash
xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner \
  -destination 'platform=iOS Simulator,id=3714FD58-944D-4020-A43E-AEE9D5DB0A57' \
  -derivedDataPath /private/tmp/area-target-ios-localization-derived \
  CODE_SIGNING_ALLOWED=YES -parallel-testing-enabled NO -collect-test-diagnostics never test
```

- [x] Run generic-device link/build with both engines in the same app:

```bash
xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/area-target-ios-localization-device \
  CODE_SIGNING_ALLOWED=NO build
```

- [x] Re-run the existing opt-in synthetic production API upload/process/download smoke if integration changes its model or asset format. Never upload private saved scans as a test.
- [x] Report implemented flow, validation and remaining device-only measurement boundaries. Do not claim real-world algorithm superiority without an actual paired on-device report. Keep the active goal open until all required functionality is implemented and verified.

Final evidence: original full regression `/private/tmp/area-target-localization-original-flat-full.log` (478 passed, one opt-in live test skipped); separate live test `/private/tmp/area-target-localization-original-live.log` (1 passed, actual downloaded features loaded by iOS native engine); signed iPhone build `/private/tmp/area-target-localization-original-iphone-final.log`; installed phone `/private/tmp/area-target-localization-phone-install.log`; final actual framework signing `/private/tmp/area-target-original-native-flat-signing-green.log`. Full test xcresult: `/private/tmp/area-target-localization-original-flat-full.xcresult`. Actual installer proved the private iOS framework needs a flat resource layout; all verified license texts remain bundled. Phone auto-launch initially blocked by device lock; after the user unlocked it, launch succeeded (`/private/tmp/area-target-localization-phone-launch-unlocked.log`). No field accuracy/ranking is claimed.
