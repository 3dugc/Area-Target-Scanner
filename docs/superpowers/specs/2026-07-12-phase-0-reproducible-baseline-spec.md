# Phase 0 Reproducible Baseline Specification (Superseded Index)

The approved Phase 0 specification has been normalized into the tracked three-file set:

- `phase-0-reproducible-baseline/requirements.md`
- `phase-0-reproducible-baseline/design.md`
- `phase-0-reproducible-baseline/tasks.md`

The content below is retained as the approved source snapshot. The three-file set is authoritative for execution and progress tracking.

**Target version:** `v1.2.1`

**Base branch:** `develop`

**Base commit:** `81d815f18eac1a55babd21dbfc2c3a7726942e84`

**Purpose:** Establish a clean, repeatable, installable baseline without changing localization algorithms or supported runtime behavior.

## 1. Scope

Phase 0 standardizes the repository, dependency metadata, build commands, CI checks, package contents, and verification evidence. It does not add Rokid support, alter coordinate mathematics, tune localization, or redesign the asset format.

## 2. Required Runnable Outputs

At the end of Phase 0, all of the following outputs must be independently runnable from a clean checkout:

1. The iOS scanner project opens and builds for a generic iOS device target; simulator execution is not treated as LiDAR support.
2. `docker compose config` validates and the web-service image builds.
3. The processing pipeline imports and its Phase 0 test suite passes in the documented Python environment.
4. The macOS native visual localizer builds and exports the required C API symbols.
5. The Unity project opens with resolved packages and its required EditMode test suite passes.
6. A generated UPM package installs into a clean Unity validation project.

Device localization accuracy is not a Phase 0 exit criterion. Device builds may be smoke-tested, but mathematical and runtime correctness changes belong to later phases.

## 3. Functional Requirements

### R0.1 — Repository hygiene

- Generated crash dumps, temporary test outputs, obsolete backup assets, and nested accidental test-output directories must not be tracked.
- Required deterministic test fixtures may remain, but their purpose and ownership must be documented.
- `.gitignore` must prevent removed generated artifacts from returning.
- Removing an artifact must not remove the only fixture used by an active test.

### R0.2 — Canonical versions

- `unity_plugin/AreaTargetPlugin/package.json` is the source of truth for the library version.
- The Phase 0 package version must be `1.2.1`.
- UPM metadata, generated artifact names, release notes, and verification output must report the same version.
- Duplicate JSON keys in `package.json` must be removed.

### R0.3 — Deterministic Unity dependencies

- `package.json` must declare each dependency once.
- The SQLite dependency must resolve through the configured package source from a clean Unity project.
- Runtime assembly references must match the declared SQLite package.
- Test-only DLLs and assemblies must not be included in the runtime UPM artifact.

### R0.4 — Native artifact contract

- Required native C API symbols must be listed in a machine-readable or script-readable contract.
- macOS native builds must verify architecture and required exports.
- The existing iOS ARM64 archive must be checked for architecture and required exports without claiming full iOS runtime certification.
- Empty Windows and Linux placeholder binaries must not be presented as supported release binaries.
- Platform binaries not included in the UPM artifact must be documented as unsupported in Phase 0.

### R0.5 — UPM packaging

- Package generation must use current runtime source, metadata, samples, and required license files.
- The generated package must contain the current alignment, debug, GLB loader, and AKAZE integration source files.
- The package must not silently reuse the stale `1.2.0` archive.
- A clean Unity validation project must install the generated package without editing package source.

### R0.6 — Unified verification entry point

- The repository must expose one documented verification command for Phase 0.
- The command must fail on the first failed required check and return a non-zero exit status.
- It must report each required check as passed, failed, or explicitly skipped with a reason.
- It must not report a device-dependent check as passed when no device was used.

### R0.7 — CI baseline

- CI must validate package metadata and Docker configuration.
- CI must run `python -m pytest tests/ -v --tb=short`; root-level research and device-analysis scripts are excluded unless moved into `tests/`.
- CI must build or compile-check the native macOS target on a compatible runner.
- CI must execute the `AreaTargetPlugin.Tests` and `AreaTargetPlugin.Tests.Property` EditMode assemblies on a configured runner, or mark the same assemblies as a documented required local gate until Unity credentials are available.
- Main and develop must use the same required status checks.

### R0.8 — Baseline documentation

- README claims must match Phase 0 capabilities.
- Build prerequisites and tested versions must be recorded.
- Scanner, Docker, native, Unity, and UPM verification commands must be documented.
- Unsupported platforms and placeholder artifacts must be stated explicitly.

## 4. Design

Phase 0 preserves the current directory and component structure. Changes are limited to repository cleanup, package/build metadata, scripts, CI configuration, tests for those changes, and documentation.

The verification flow is organized as independent checks under one orchestrating entry point:

```text
repository metadata
    → Python/import tests
    → Docker configuration and image build
    → native macOS build/export verification
    → iOS archive static inspection
    → Unity dependency and EditMode verification
    → UPM package generation and clean-project install
```

Checks may be invoked individually during development. The full Phase 0 gate invokes them in the documented order and stops on failure.

## 5. Compatibility Rules

- Asset bundle format remains version 2.0.
- Existing ORB, AKAZE, BoW, PnP, consistency, and alignment behavior remains unchanged.
- Existing public Unity types and method signatures remain unchanged unless a compile failure makes a metadata-only correction unavoidable.
- Existing scan ZIP structure remains unchanged.
- Existing Docker service names and public port remain unchanged unless the current configuration cannot start; any required correction must preserve documented usage.

## 6. Test Design

Phase 0 adds or updates tests for:

- Unique and valid UPM metadata fields.
- Version consistency across source and generated package.
- Required package file inclusion and forbidden test/generated file exclusion.
- Native archive architecture and required symbol presence.
- Verification-script exit behavior for pass, fail, and skipped device checks.
- Docker Compose configuration validity.
- Clean-install resolution of AR Foundation and `com.gilzoide.sqlite-net` in a temporary Unity validation project.

Existing algorithm tests are run as regression evidence but are not rewritten unless Phase 0 exposes an actual baseline defect.

## 7. Acceptance Criteria

Phase 0 is complete only when:

- The worktree is clean after the full verification flow.
- All required Phase 0 checks pass from a clean checkout on the development Mac.
- The latest CI run for the Phase 0 commit is green for all configured jobs.
- The generated `com.areatarget.tracking-1.2.1.tgz` installs into a clean Unity project.
- The installed sample compiles and enters its documented Editor-safe state.
- The macOS native library and existing iOS archive expose the required API symbols.
- Documentation contains no claim that Rokid, Android ARM64, Windows, or Linux is production-supported in Phase 0.
- A rollback reference to base commit `81d815f` is recorded in the Phase 0 release notes.

## 8. Risks and Controls

### Unity CI credentials

Unity automation may require a license or CI secret. Until configured, Unity verification remains a mandatory recorded local gate and CI must not label it as passed.

### Large tracked fixtures

Removing large fixtures can break regression tests. Every candidate is checked for references before removal; retained fixtures are documented instead of deleted solely for size.

### Stale release artifacts

Existing `1.2.0` archives may remain for historical reference, but build and verification commands must generate and select `1.2.1`. Documentation must not direct users to stale artifacts.

### Platform claims

The presence of CMake branches or empty placeholder files is not evidence of platform support. Only a built, packaged, and verified artifact may be listed as supported.

## 9. Non-Goals

Phase 0 explicitly excludes:

- Rokid SDK integration.
- Android ARM64 native builds.
- Coordinate-alignment corrections.
- Background localization.
- Localization parameter tuning.
- Accuracy or latency certification.
- New user-facing scanner features.
- Asset-format migration.

These items remain assigned to later approved phases in the internal commercial readiness design.
