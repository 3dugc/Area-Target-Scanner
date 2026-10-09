# M0 execution baseline

Recorded 2026-10-05. Implementation is isolated on `codex/area-target-runtime-v2`, from local core commit `0495d644cd9c6114f4e3f1b051557b23acff54a7`. Existing iOS/Immersal/UI changes stay in the original workspace. The source tree and original dirty delta are recorded under the controlled local directory `/private/tmp/area-target-runtime-v2-baseline/`; source patch and binary artifacts are not committed.

| Check | Result |
|---|---|
| pythonPhase1NativeDB | PASS:67 tests |
| nativeFixtureTool | PASS:1 |
| nativeVerificationTool | PASS:1 |
| legacyMacOSBuildCTestSymbols | PASS:1 CTest |
| iosUnsignedDeviceBuild | PASS |
| iosSimulatorXCTest | FAIL baseline:537 passed,2 keychain credentialStorage failures,3 live-service opt-in skips; simulator diagnostics timed out |
| unityLegacyEditMode | PASS:992/992 on temporary source copy, Unity6000.6.3f1; project/default versions unavailable and temporary dependencies upgraded |
| unityLegacyUPM | Metadata1.3.0 PASS; package FAIL missing opencv_ios/opencv2.framework, clean install not run |
| unityV2SDKIntegration | DEFERRED by current M0/M1 scope |
| physicalAccuracy | NOT_MEASURED; user chose tools first |

Host OpenCV 4.11.0; existing private iOS OpenCV 4.10.0; Xcode 27.0 (27A5237l); arm64. Dependency differences remain explicit until same-data cross-build replay verifies compatibility.

Legacy macOS rollback artifact SHA256: `f7bcb8db0e3bf1c38fa0c5853a4b80867fd0f5a90a460406eecff1e2ec68d9b3`. The previous iOS private framework is also preserved with a digest in local baseline.json. Rollback means selecting the original API/preset and preserved artifact; no existing maps or scans are rewritten.

Optimizer gitlink and checked-out commit differ and are recorded; this task does not change them or service APIs. The real native known-pose production-SQLite XCTest passed. Existing keychain storage tests failed before the v2 integration (`credentialStorage`); this task preserves their failure in the baseline and does not alter account storage. Result bundle: `/private/tmp/atc-ios-baseline.xcresult`, complete log: `/private/tmp/atc-ios-baseline.log`. Physical accuracy has no evidence yet: the user requested tooling first, then iOS collection.

Unity baseline logs and source-copy hashes: `/private/tmp/area-target-m0-unity-ojgskvay/report.json`. The original project source was preserved; Unity may update its normal global cache/test-result locations. This records a compatible-editor test run, not a fixed-version package release.
