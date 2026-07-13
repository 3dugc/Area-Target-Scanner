# iOS Tracker Main-Thread Initialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the iPhone acceptance app's `get_version can only be called from the main thread` failure while preserving background SQLite/native initialization, then resume Task 9 device evidence collection.

**Architecture:** `SLAMTestSceneManager` constructs and cleans up the temporary `AreaTargetTracker` on Unity's main thread. Only the existing `Initialize(assetPath)` workload runs inside `Task.Run`; the localization algorithm, public API, map format, and async frame runner remain unchanged.

**Tech Stack:** Unity 6000.4.6f1, C# async/await, NUnit EditMode tests, AR Foundation/ARKit, Xcode, `xcrun devicectl`.

---

### Task 1: Enforce the Tracker Thread Boundary

**Files:**
- Modify: `unity_plugin/AreaTargetPlugin/Tests/SLAMTestSceneManagerTests.cs`
- Modify: `unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs`
- Modify: `docs/superpowers/specs/phase-1-ios-workflow/tasks.md`
- Modify: `docs/superpowers/plans/2026-07-14-ios-main-thread-tracker-init.md`

- [ ] **Step 1: Write the failing EditMode source-contract test**

Add this test to `SLAMTestSceneManagerTests`:

```csharp
[Test]
public void TrackerInitialization_CreatesAndDisposesTrackerOutsideBackgroundBlock()
{
    string source = File.ReadAllText(Path.Combine(
        Application.dataPath, "Scripts", "SLAMTestScene", "SLAMTestSceneManager.cs"));
    int trackerCreation = source.IndexOf(
        "AreaTargetTracker tracker = new AreaTargetTracker();",
        StringComparison.Ordinal);
    int backgroundStart = source.IndexOf("await Task.Run(() =>", StringComparison.Ordinal);
    int backgroundEnd = source.IndexOf("// 回到主线程", backgroundStart, StringComparison.Ordinal);
    string backgroundBlock = source.Substring(backgroundStart, backgroundEnd - backgroundStart);

    Assert.That(trackerCreation, Is.GreaterThanOrEqualTo(0));
    Assert.That(trackerCreation, Is.LessThan(backgroundStart));
    Assert.That(backgroundBlock, Does.Not.Contain("new AreaTargetTracker()"));
    Assert.That(backgroundBlock, Does.Not.Contain("tracker.Dispose()"));
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
/Applications/Unity/Hub/Editor/6000.4.6f1/Unity.app/Contents/MacOS/Unity \
  -batchmode -nographics -buildTarget iOS \
  -projectPath unity_project \
  -runTests -testPlatform EditMode \
  -testFilter AreaTargetPlugin.Tests.SLAMTestSceneManagerTests.TrackerInitialization_CreatesAndDisposesTrackerOutsideBackgroundBlock \
  -testResults phase1-results/tracker-main-thread-red.xml \
  -logFile phase1-results/tracker-main-thread-red.log
```

Expected: FAIL because tracker construction and disposal are inside `Task.Run`.

- [ ] **Step 3: Implement the minimum main-thread boundary change**

Use this shape in `InitializeTrackingAsync`:

```csharp
string trackerAssetPath = assetPath;
AreaTargetTracker tracker = new AreaTargetTracker();
bool initOk = false;
string initError = null;
var bgLog = new List<string>();

await Task.Run(() =>
{
    try
    {
        initOk = tracker.Initialize(trackerAssetPath);
        bgLog.Add($"Tracker.Init: {(initOk ? "OK" : "FAIL")}");
        if (!initOk)
            initError = "Tracker 初始化失败";
    }
    catch (Exception ex)
    {
        bgLog.Add($"Tracker.Init异常: {ex.GetType().Name}");
        bgLog.Add($"  {ex.Message}");
        initError = ex.Message;
    }
});

// 回到主线程
log.AddRange(bgLog);
if (!initOk)
{
    tracker.Dispose();
    tracker = null;
}
```

Keep the existing error UI, successful `_tracker = tracker`, frame subscription, and GLB loading unchanged.

- [ ] **Step 4: Run focused and affected EditMode tests and verify GREEN**

Run the focused command from Step 2 with `green` result/log filenames, then:

```bash
/Applications/Unity/Hub/Editor/6000.4.6f1/Unity.app/Contents/MacOS/Unity \
  -batchmode -nographics -buildTarget iOS \
  -projectPath unity_project \
  -runTests -testPlatform EditMode \
  -testFilter AreaTargetPlugin.Tests.SLAMTestSceneManagerTests \
  -testResults phase1-results/tracker-main-thread-suite.xml \
  -logFile phase1-results/tracker-main-thread-suite.log
```

Expected: both invocations pass with zero failures.

- [ ] **Step 5: Record evidence and commit the fix**

Keep Task 9 Step 3 unchecked, record RED/GREEN evidence, run `git diff --check`, and commit only the two code files plus the task and plan files with message `fix: create iOS acceptance tracker on main thread`.

### Task 2: Rebuild and Resume iPhone Task 9 Evidence

**Files:**
- Generated only: `.worktrees/phase1-ios-workflow/phase1-results/ios-p1-a/device-upm-project-current/`
- Generated only: `.worktrees/phase1-ios-workflow/phase1-results/ios-p1-a/device-derived-data-current/`
- Modify only after valid evidence: `docs/phase-1-ios-validation.md`
- Modify: `docs/superpowers/specs/phase-1-ios-workflow/tasks.md`
- Modify: `docs/superpowers/plans/2026-07-14-ios-main-thread-tracker-init.md`

- [ ] **Step 1: Refresh the ignored acceptance scene and export iOS**

Copy the fixed scene manager into the existing clean-UPM acceptance project. Run `AreaTargetPlugin.Editor.AreaTargetIosXrBootstrap.Configure` and `BuildiOS.BuildDevelopment` in separate Unity invocations. Expected: both return 0 and the export reports `Build Finished, Result: Success`.

- [ ] **Step 2: Sign, build, install, and launch on the connected iPhone**

Use the already-authorized signing identity and device identifier only as shell-local values. Build the existing Xcode project into `device-derived-data-current`, install `AreaTargetPhase1Acceptance.app`, and launch `com.areatarget.phase1.acceptance` with `devicectl --console`. Expected: no `get_version` exception; UI/logs show `Tracker.Init: OK`, `帧订阅: OK`, `初始化完成!`, and `定位运行器: 已启动`.

- [ ] **Step 3: Collect localization and privacy-safe diagnostic evidence**

Keep the app foregrounded and aim at the scanned area until at least one `TRACKING`/`LOCALIZED` result. Background once to trigger export, retrieve the newest JSONL, then run:

```bash
shasum -a 256 "$PHASE1_DIAGNOSTIC_JSONL"
rg -n "ImageData|JPEG|ScanData|/Users/|file://" "$PHASE1_DIAGNOSTIC_JSONL"
```

Expected: a SHA-256 value and no privacy-scan output. If localization fails, keep Task 9 Step 3 unchecked and record the real failure category.

- [ ] **Step 4: Update Task 9 evidence and commit only anonymized documentation**

Mark Task 9 Step 3 complete only if SQLite/native initialization, one localization, diagnostic export, and privacy scan all pass. Commit only anonymized documentation; never add generated builds, raw logs, scan ZIPs, map databases, images, absolute paths, signing identity, or device identifier.
