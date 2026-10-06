# Whole-project OpenCV 5 integration plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent implementation tasks below. Preserve the original workspace's unrelated pending changes and collect actual test evidence before merging.

**Goal:** Unify project-controlled OpenCV runtimes on 5.0.0, including the pending Swift iOS Area Target entry point, keep Immersal compatibility, validate the latest develop integration, and merge locally when the available integration gates pass.

**Architecture:** Retain ORB/AKAZE/Hamming/PnP settings, map layout and the existing C ABI. Reuse the pinned OpenCV + contrib sources for macOS, iPhoneOS and arm64 iPhoneSimulator; keep AreaTargetNative's OpenCV implementation private so Immersal's proprietary SDK remains independently linkable. Upgrade Swift producer/engine identities together with fixture and framework provenance, and reject stale 4.x dependencies rather than silently accepting them.

**Tech Stack:** Python 3.11 / NumPy 2 / OpenCV 5.0.0 + contrib, C++17, CMake, Swift, Xcode 27, Unity.

**Authorization:** The user approved integrating latest develop and completing the Swift iOS upgrade, then clarified that the target is the entire project and that iOS must retain Immersal compatibility. No further design/merge permission is needed for the agreed local work. Publishing, remote push, SDK replacement and production deployment are outside this task.

## Task 1: Protect the workspace and align the integration base

- [x] Snapshot modified/untracked original files, Git patches and hashes. After temporary paths were lost during session continuation, restore a persistent snapshot at `build/opencv5-unification/original-state`; preserve the dirty model_optimizer submodule in place.
- [x] Merge latest `origin/develop` (`60d88bb`, then `ea7989e`) into `codex/opencv5-upgrade`; both merges completed without conflicts. The newer Swift login files are reconciled with the pending app without dropping its workspace/localization features.
- [x] Import only the existing OpenCV-specific native iOS tooling and AreaTargetNative interface into the isolated branch. Do not import unrelated pending Swift features or the proprietary Immersal binary into the branch commit.
- [x] Record a full active-entry-point inventory, distinguishing historical OpenCV 4 comparisons and third-party SDK internals from project-controlled runtime dependencies.

| Active entry point | Project-controlled dependency/identity |
| --- | --- |
| Python pipeline and Flask service | Both requirements pin contrib headless 5.0.0.93; AKAZE factory supports the 5 contrib namespace, producer metadata records the actual version, and the actual runtime version is part of cache identity. |
| Docker and CI/deploy jobs | Install those same requirements; Docker executes ORB/AKAZE/PnP import checks, and CI shares matched rebuilt native artifacts. |
| Unity managed and native paths | Managed code uses NativeLocalizerBridge's unchanged 11 C APIs; native CMake/macOS/iOS defaults and UPM framework validation require 5. No active OpenCvSharp4, Emgu or OpenCVForUnity runtime dependency was found. |
| Pending Swift iOS app | Private AreaTargetNative device/simulator build, verifier and descriptor fixture producer are upgraded together; live/replay engine identity and app integration are validated in Task 3. |
| Retained OpenCV 4 references | Explicit comparison input preparation, old descriptor compatibility tests, optional baseline build branches, stale dependency rejection tests and historical records. They do not select the default production runtime. |
| Immersal SDK | Preserve proprietary SDK 2.4.0 and its bundled private implementation. Do not relabel it OpenCV 5. Verify coexistence through private symbols and an actual device composite link. |

## Task 2: Private Apple native framework and fixture migration

**Files:** `tools/ios/build_area_target_native.py`, `verify_area_target_native.py`, both existing `.test.py` files, `generate_native_fixture.py`, `generate_native_fixture.cpp`, `tools/opencv5/build_ios_dependency.sh`, `ios_scanner/AreaTargetScanner/ThirdParty/AreaTargetNative/`.

- [x] Write and observe failing checks that reject 4.x/basic 5 dependencies and require matching OpenCV 5 + contrib source provenance for both device and simulator artifacts.
- [x] Extend the pinned Apple dependency builder for the simulator platform, keeping device defaults intact and platform output/cache identities separate. Use the already verified source archive digests.
- [x] Build private AreaTargetNative for both Apple platforms from the shared version-aware C++ source. Keep exact 11 C exports, a two-level namespace, platform/SDK/minimum-version metadata and no imported OpenCV C++ implementation symbols.
- [x] Generate fixture descriptors with the pinned OpenCV 5 macOS dependency, eliminating active pkg-config/opencv4 assumptions. Test real known-pose tracking, AKAZE fallback and blank LOST behavior.
- [x] Include the correct OpenCV 5/contrib and linked-dependency notices; validate the included notice bytes and actual framework binary digest.
- [x] Run real device/simulator builds and private framework contract tests. Fully link device AreaTargetNative together with the existing Immersal SDK and verify both APIs coexist. Do not replace or relabel the proprietary SDK.

**Commands:** `python3 tools/ios/generate_native_fixture.test.py`; `python3 tools/ios/verify_area_target_native.test.py`; configure pinned dependency caches explicitly for reproducibility. Capture all actual command arguments and outputs in the final validation record.

## Task 3: Swift app identity and integration compatibility

**Files:** Original pending `AreaTargetLocalizationSession.swift`, `LocalizationReplayAdapters.swift`, their tests, and relevant pending iOS documentation. Keep these files' unrelated functional changes pending rather than committing them wholesale as part of the OpenCV migration.

- [x] Update the existing behavioral identity assertion to OpenCV 5 and observe it fail against the current 4.10 identity.
- [x] Use one current engine identity in live and replay paths; retain SDK/channel separation and existing report schema semantics.
- [x] Verify test fixtures and replay provenance advertise the actual new descriptor producer/runtime. Remove active 4.x assumptions in the app-owned paths; keep historical evidence marked historical.
- [x] Compile the current pending app with the upgraded native implementation in an isolated overlay of the preserved workspace. Run appropriate simulator unit/contract tests and unsigned device linking with Immersal included.
- [x] Verify Area Target/Immersal switching, local map and report paths preserve their current behavior; report unavailable live SDK/device acceptance explicitly.

## Task 4: Latest develop regression and release tooling

**Files:** Current CI, Dockerfile, requirements, pipeline/service tests, Unity XR serialization test if its existing editor-version assumption is reproducibly wrong, upgrade documentation.

- [x] Inspect the automatic merge for dependency pins, AKAZE factory, producer metadata and cache invalidation; preserve the newly integrated service/authentication/mobile API behavior.
- [x] Run `VL_NATIVE_LIBRARY=... python tools/opencv5/run_regression.py --import-mode=importlib` on the latest integrated tree. Require complete fresh JUnit reports for both groups; never count a native early exit as success.
- [x] Rebuild/deploy matched Unity artifacts, run native CTest/ABI and UPM tests. Run the current CI lint scope and validate Docker Compose.
- [x] Resolve the existing Unity XR serialization assertion through a meaningful failing test and an editor-version-compatible semantic check if needed, then rerun EditMode and clean package/export/link gates in the isolated Unity project.
- [x] Run actual linux/arm64 Docker image construction and isolated container runtime checks. The first Open3D import failed on missing libgfortran.so.5; after installing the runtime and separating cached install/check layers, image construction and ORB/AKAZE/PnP, ELF dependency, authentication and actual Gunicorn startup/shutdown checks all returned 0. No remote publishing/deployment.
- [x] Inspect device visibility before attempting signed/runtime checks. Missing hardware or real cross-session inputs remains missing evidence, not a pass or a reason to claim recognition-rate improvement.

## Task 5: Review, commit and local develop integration

- [x] Independently review spec compliance and implementation quality, including project runtime version inventory and Area Target/Immersal private-symbol separation.
- [x] Update the validation report with latest baseline, whole-project coverage, actual runtime versions, commands, test totals, binary hashes, limitations and pending device/field gates.
- [x] Commit only OpenCV-specific branch changes. Preserve the original Swift functionality and model_optimizer changes, including file contents and pending Git state as applicable.
- [x] Prepare a reviewed integration of the original pending README changes. Fast-forward the validated branch into local develop while preserving other pending files; switch the original Python environment offline to a single contrib headless 5 package and verify native/SDK contracts in the actual workspace. Merge and activation returned 0; post-cutover smoke 16/16, dependency 11/11 and real fixture 1/1 passed.
- [x] Confirm develop and the upgrade branch have the same commit, contain latest origin/develop, and use the validated runtimes. The actual 303-check audit passed all 179 file policies (168 strict preservation, 170 byte-identical, 9 reviewed changes), fixed artifact/resource hashes, dirty model_optimizer preservation and an empty index. No push or publication. Keep the upgrade worktree and cached proof artifacts.

## Acceptance boundary

All project-controlled default dependencies and iOS runtime identities must be OpenCV 5, with AKAZE available. Immutable third-party SDK internals are not rewritten. The app must continue to link Immersal through its existing SDK/C ABI; AreaTargetNative must not expose or bind another SDK's OpenCV C++ implementation. Missing phone/iPad or field datasets does not establish live localization acceptance. No algorithmic quality gain is claimed from a version change.
