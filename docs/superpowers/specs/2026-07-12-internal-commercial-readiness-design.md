# Area Target Scanner Internal Commercial Readiness Design

**Date:** 2026-07-12

**Status:** Approved direction; implementation is divided into independently runnable phases.

## 1. Objective

Mature the existing Area Target Scanner repository into a library that can be reused by internal Unity projects for commercial applications. The library must keep the current architecture and support this primary workflow:

1. Scan a 20–100 m² indoor area with a LiDAR-equipped iPhone or iPad.
2. Process the scan locally through Docker without uploading customer data.
3. Load the generated Area Target assets in Unity.
4. Localize and render stable content on both iOS and Rokid AR Studio.

The target operating metrics are:

- Translation error no greater than 10 cm under accepted environment conditions.
- Rotation error no greater than 3 degrees.
- P90 initial localization time no greater than 3 seconds.
- Relocalization success rate of at least 95% in the validation dataset.
- Application rendering at 30 FPS or better on supported reference devices.
- Two-hour continuous operation without crashes or sustained memory growth.

## 2. Delivery Constraints

- Development is performed by one AI coding agent with user-assisted device access.
- The user can connect Rokid AR Studio and LiDAR-equipped iOS devices to the development Mac for builds, installation, logging, and device tests.
- The current Swift scanner, Python/Docker processing pipeline, C++ localizer, and Unity package remain the architectural foundation.
- Each phase must end with an installable, runnable, and reversible version.
- New features that do not directly support internal commercial readiness are excluded.

## 3. Existing Architecture to Preserve

### iOS scanner

The native Swift application captures ARKit mesh data, keyframe images, camera poses, and camera intrinsics. It exports a scan archive consumed by the processing pipeline.

### Local processing pipeline

The Python pipeline and web service run locally through Docker. They optimize the model, unwrap and project textures, extract ORB and AKAZE features, build the feature database, and emit a versioned asset bundle.

### Native localization core

The C++ library performs feature extraction, BoW candidate retrieval, ORB matching, AKAZE fallback, PnP estimation, consistency filtering, alignment handling, and debug reporting.

### Unity runtime

The Unity package loads asset bundles and feature databases, invokes the native localizer, smooths poses, and exposes platform and scene-update abstractions. iOS uses AR Foundation/ARKit. Rokid support will be added through the existing platform abstraction.

## 4. Delivery Strategy

The project follows a reliability-first sequence. iOS is completed before Rokid because it provides an existing scanner, runtime platform implementation, and reference coordinate system. Rokid then reuses the validated asset format, native localizer, Unity API, and test dataset.

Every phase produces a tagged internal version. A later phase may improve a previous version, but it must not leave the repository in a state where the previous supported workflow cannot run.

## 5. Phase Roadmap

### 阶段 0——可重复构建基线（`v1.2.1`）

Create a clean and repeatable baseline without changing localization behavior. From a clean checkout, the scanner, Docker pipeline, native smoke test, Unity Editor test project, and UPM package must build through documented commands. Repository artifacts, package metadata, dependencies, CI coverage, and verification commands are normalized.

阶段 0 的正式中文规范位于 `phase-0-reproducible-baseline/requirements.md`、`design.md` 和 `tasks.md`。

### Phase 1 — Complete iOS workflow (`v1.3.0`)

Deliver the full scan-to-localization workflow on iOS. Correct the relationship between PnP map pose, ARKit capture pose, and Unity world pose; move localization work off the Unity main thread; package the iOS native library and SQLite dependency; and validate multiple real spaces.

The phase exits when at least three 20–100 m² environments can be scanned, processed, loaded, localized, and run continuously for 30 minutes on reference iOS devices.

### Phase 2 — Rokid AR Studio workflow (`v1.4.0`)

Add a Rokid implementation under the existing Unity platform interface. Integrate the supported Rokid UXR/OpenXR SDK, acquire synchronized camera frames and head poses, convert coordinate conventions, build the Android ARM64 native library, and ship a Rokid sample scene and diagnostic flow.

The phase exits when the same processed map works on both iOS and Rokid AR Studio, and Rokid can run continuously for 30 minutes and recover automatically after localization loss.

### Phase 3 — Accuracy and performance release candidate (`v1.5.0-rc`)

Build a measured multi-device dataset, calibrate image and camera transformations, tune ORB/AKAZE/BoW/PnP behavior, add bounded background processing, reject stale results, and validate adverse conditions. ARKit and Rokid VIO provide frame-to-frame stability while visual localization establishes and corrects the global map relationship.

The phase exits only when the target accuracy, latency, recovery, frame-rate, memory, and two-hour stability criteria are met on the reference devices.

### Phase 4 — Internal commercial release (`v1.6.0`)

Freeze the supported public API, produce one versioned UPM artifact with iOS and Android ARM64 dependencies, provide integration and diagnostic samples, implement structured errors and log export, automate release generation and rollback, and validate integration in an internal product that does not modify library source code.

The phase exits when another internal Unity project can integrate the library using only the published package and documentation.

## 6. Cross-Phase Quality Gates

Each phase must meet all of these gates:

- A clean checkout can execute the documented build and verification flow.
- Required automated checks pass before an internal release tag is created.
- Device-dependent checks have a recorded device model, OS version, application build, map identifier, and result.
- The UPM artifact version matches the source version and release notes.
- The previous supported workflow has a documented rollback artifact.
- Known limitations are explicit and do not contradict README claims.

## 7. Error Handling and Diagnostics

The library must distinguish asset errors, platform acquisition errors, native initialization errors, localization failure, consistency rejection, stale results, and unsupported-device failures. Failures must not move content to an unverified pose. Device logs must include build version, map version, localizer mode, feature counts, inlier count, timing, and tracking state without including captured images by default.

## 8. Testing Strategy

Testing is layered:

- Python unit, property, integration, and pipeline tests.
- C++ native API and deterministic localization tests.
- Unity EditMode tests for package behavior and coordinate math.
- Unity PlayMode tests for lifecycle, background processing, and scene updates.
- iOS build and device smoke tests.
- Rokid Android ARM64 build and device smoke tests.
- Recorded-sequence regression tests shared by iOS and Rokid.
- Measured real-space acceptance tests for accuracy and latency.

Mock-based tests remain useful for fault handling, but they do not satisfy an end-to-end release gate.

## 9. Explicit Non-Goals

The first internal commercial release does not include:

- Spaces larger than 100 m² or multi-area map federation.
- Cloud map processing or hosted map storage.
- General Android phone support.
- Production Windows or Linux SDK distribution.
- Embedding the scanning workflow into every business application.
- Learned-feature replacement such as SuperPoint or NetVLAD.
- Shared multi-user anchors.

These items require separate approved specifications after `v1.6.0`.

## 10. Working Method

Each phase receives its own specification and tracked task list. Work is completed one task at a time using test-first changes where applicable. A task is complete only when its implementation, automated checks, relevant device verification, documentation, and task checkbox all agree.
