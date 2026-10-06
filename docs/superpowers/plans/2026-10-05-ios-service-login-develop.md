# iOS Service Login on develop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute the independent implementation and review tasks in this session.

**Goal:** Land the authorized iOS Area Target service login on develop, preserving unrelated local work and the current production release.

**Architecture:** Start from origin/develop 60d88bb312e7fc5c79270531b0906e7cb8c0df19 in an isolated managed worktree. Add the minimal remote processing foundation needed for authenticated upload, resumable job status and verified asset download. Use origin-bound Keychain sessions and retain separate per-job Bearer credentials. Integrate the native login form into the existing scan and Immersal interface without importing the unrelated workspace, localization or native SDK changes.

**Tech Stack:** SwiftUI, Foundation URLSession, Security Keychain, CryptoKit, ZIPFoundation, XCTest, Xcode, GitHub Actions.

---

## Scope and file ownership

- iOS implementation worker: Models/AreaTargetProcessingJob.swift; Services/AreaTargetAPIClient.swift, AreaTargetAssetStore.swift, AreaTargetJobStore.swift, AreaTargetProcessingModel.swift, AreaTargetScanArchive.swift, ScanSourceFingerprint.swift; Views/AreaTargetProcessingView.swift; minimal ContentView.swift and project.pbxproj integration; focused API, model, archive, asset, fingerprint and rendered login tests.
- Root: this plan, user instructions, verification evidence, Git integration and exact-SHA CI monitoring.
- Independent reviewer: authentication, source deletion protection, redirect/origin isolation, error handling and the rendered native entry.

## Tasks

- [x] Copy the audited processing dependency closure into the clean develop baseline; remove unrelated localization and workspace UI dependencies.
- [x] Add the Area Target account/tasks entry and scan upload entry; preserve existing Immersal behavior and protect active cloud source scans from deletion.
- [x] Register only the necessary source and tests in the Xcode project; keep passwords and runtime credentials out of Git.
- [x] Run meaningful client and integration tests on an available iOS simulator, plus an unsigned generic iOS device build. Resolve actionable independent review findings.
- [x] Document the native login flow and verification limits.
- [ ] Commit explicit files, push the tested commit to develop without force, and wait for both CI and Deploy to succeed on that exact commit.

## Release boundary

The user requested develop only. Do not promote main or publish, alter image tag policy, deploy production or install the phone build. develop CI publishes only the existing develop image tags. Local simulator and generic-device builds verify client code; signed-device interaction remains a separate acceptance step. Preserve the original dirty checkout and all unrelated worktrees.

## Verification

Fresh verification on this isolated develop baseline completed on 2026-10-05:

- Full AreaTargetScanner scheme on iPhone 17 Pro / iOS 26.5 simulator: 277 tests passed, 0 failed, 0 skipped, including 108 focused processing/login tests and the original scan/Immersal suites.
- Simulator tests use local ad-hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so both real Keychain round-trip tests execute with the required identity. The initial unsigned run failed those two tests; no tests were skipped or weakened to obtain the final result.
- Generic iOS device build with signing disabled: BUILD SUCCEEDED. No phone install was performed.
- Independent read-only review found no blocking authentication or integration defect. Login component rendering was tested; full phone navigation and a real signed-device cloud scan remain separate acceptance steps.
- `git diff --check` and `plutil -lint` passed. Core processing sources were copied without unrelated workspace/native dependencies.

The final release checklist is executed after this implementation commit. Verify its exact SHA in both GitHub Actions workflows; the develop branch and the Actions records provide the final remote evidence.
