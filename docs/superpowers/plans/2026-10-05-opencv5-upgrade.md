# OpenCV 5 isolated upgrade implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task. Track the checks below as evidence is collected.

**Goal:** Upgrade the committed develop baseline to OpenCV 5 on a separate branch and produce reproducible comparison evidence before considering integration.

**Architecture:** Keep ORB, AKAZE, Hamming BoW, PnP, filtering, the C ABI, and their algorithm parameters unchanged. Pin Python and native OpenCV dependencies, rebuild platform artifacts, invalidate cached feature bundles, and compare identical input cases in separate OpenCV 4/5 processes. Do not merge, publish, or include unrelated uncommitted iOS work.

**Tech stack:** Python 3.11, OpenCV 5.0.0 / Python wheel 5.0.0.93, C++17, CMake, Xcode, Unity.

**Baseline:** `0495d64` (local committed develop). Branch: `codex/opencv5-upgrade`. The original checkout remains on develop.

## Task 1: Isolate dependencies and record the baseline

- [x] Create and attach a managed worktree and an upgrade branch at the approved committed baseline.
- [x] Use the existing Python 4.13.0.92 environment read-only and build a separate Python environment for 5.0.0.93.
- [x] Configure a baseline native build against the existing OpenCV 4.11.0 installation in a separate output directory; run CTest and symbol validation.
- [x] Download and verify official OpenCV / contrib 5.0.0 source archives, verify cached source contents, and build minimal static macOS and iPhoneOS dependencies. The basic iOS release archive cannot preserve AKAZE, so it is not used as the runtime dependency.

## Task 2: Python pipeline and cache version

Files: `requirements.txt`, `web_service/requirements.txt`, `web_service/app.py`, relevant pipeline/cache tests.

- [x] Pin one contrib headless OpenCV package at `5.0.0.93` consistently; retain the default AKAZE factory in its OpenCV 5 namespace and identical other dependencies for the comparison.
- [x] Add a behavioral regression proving a feature-bundle cache from the old producer cannot be reused by the new producer; observe the failure before changing the producer/cache identity.
- [x] Record OpenCV producer version in generated asset metadata while preserving the descriptor format and all feature parameters.
- [x] Run pipeline, database, service, and end-to-end tests under OpenCV 5. Final guarded regression: 355 passed, 6 explicitly skipped; both pytest groups wrote complete JUnit reports.

## Task 3: Native and iOS migration

Files: `native_visual_localizer/CMakeLists.txt`, native feature/geometry headers, `native_visual_localizer/build_macos.sh`, `native_visual_localizer/build_ios.sh`, native tests.

- [x] Replace the OpenCV 4 module assumptions with version-aware 4/5 module selection so the same algorithm source can support a controlled baseline comparison.
- [x] Accept an explicit OpenCV install/build directory in build scripts so experiments do not overwrite the original artifacts or depend on a global Homebrew upgrade.
- [x] Pin OpenCV / contrib source digests for the iOS framework; validate version, architecture and binary provenance so stale 4.x or basic 5 caches cannot be reused.
- [x] Rebuild macOS and iOS native artifacts, run native contract tests, verify exact C symbols and architecture, and fully link the iPhoneOS wrapper/framework. Include dependency licenses and eliminate macOS installation-specific dynamic dependencies.

## Task 4: CI and comparative verification

Files: `.github/workflows/ci.yml`, `Dockerfile`, a comparison runner under `tools/opencv5/`, focused tests.

- [x] Configure CI to use the pinned OpenCV 5 Python and native dependencies and a verified iOS dependency, without installing two competing cv2 packages. Linux UPM content tests consume artifacts rebuilt by the macOS job.
- [x] Make Docker smoke-test actual ORB/AKAZE and PnP availability. Compose configuration passed; image build was unavailable because the Docker daemon was not running and is recorded as NOT_RUN.
- [x] Compare ORB/AKAZE extraction, matching, deterministic noisy/non-coplanar PnP, and positive/negative native localization in separate processes using the same input hashes, algorithm parameters, NumPy version, thread settings, and warmup policy. Repeat in reverse order to inspect timing variability.
- [x] Report quality counts and median/P95 time; never interpret synthetic matching as field recognition accuracy. Treat missing real scans or physical devices as explicit missing acceptance evidence.

## Task 5: Review and retain the experiment

- [x] Run required regression checks, inspect the diff, and request independent review of scope and code quality. Native/UPM/Python checks passed. Unity EditMode recorded 991 passes and one existing XR YAML serialization assertion affected by the available newer Editor; this gate remains incomplete. Clean UPM installation, iOS export and unsigned generic-device Xcode linking passed.
- [x] Save exact versions, commands, results, skipped gates, and an integration recommendation in `docs/opencv5-upgrade-validation.md`; retain both measurement orders in `docs/opencv5-comparison-results.json`.
- [x] Commit only upgrade changes on the new branch. Keep the worktree available and do not merge or push unless separately requested. Independent final review found no blocking issues; field/device acceptance remains outstanding and is not claimed as complete.

## Acceptance criteria

Existing positive native localization must succeed with bounded pose error; blank or invalid input must remain LOST. The public C ABI, old database byte layout, and algorithm thresholds remain unchanged. Available regression gates must pass; missing gates must not be counted as passing. A recommendation to integrate requires real-scene localization non-regression and a demonstrated benefit, beyond successful compilation.
