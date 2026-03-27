# iOS On-Device Test Guide

Because the simulator can only pretend so hard.

## Prerequisites

- macOS + Xcode installed
- Unity 6000.3.11f1 (installed at `/Applications/Unity/Hub/Editor/6000.3.11f1/`)
- iPhone/iPad connected via USB, iOS 16.0+
- Apple Developer account signed in to Xcode

## Pre-flight Checklist

| Item | Status |
|------|--------|
| SLAMTestAssets (features.db, manifest.json, optimized.glb) | ✅ Ready |
| ARTestSceneManager default path → SLAMTestAssets | ✅ Fixed |
| ARTestSceneManager asset pre-check | ✅ Added |
| ARTestSceneManager debug UI (Quality/Mode/AKAZE/Consistency) | ✅ Added |
| InternalsVisibleTo("Assembly-CSharp") | ✅ Added |
| BuildiOS.cs scene list includes ARTestScene | ✅ Confirmed |
| iOSPostProcess.cs (OpenCV/Bitcode/system frameworks) | ✅ Confirmed |
| build_ios.sh 11-symbol verification | ✅ Complete |
| **iOS static library libvisual_localizer.a** | ⚠️ **Needs rebuild** |

> The current `libvisual_localizer.a` is from March 24 and is missing `vl_add_keyframe_akaze` and `vl_set_alignment_transform`. It's living in the past.

---

## Step 1: Rebuild the iOS Static Library

```bash
cd native_visual_localizer
bash build_ios.sh
```

Expected behavior:
- Auto-downloads OpenCV iOS framework (~200MB first time, cached after that — go grab a coffee)
- Compiles arm64 static library
- Verifies all 11 exported symbols (no WARNINGs)
- Backs up old library as `.bak`, copies new one to `unity_project/Assets/Plugins/iOS/`

Verify:
```bash
nm unity_project/Assets/Plugins/iOS/libvisual_localizer.a | grep " T _vl_"
```
You should see 11 symbols starting with `_vl_`. If you see fewer, something went wrong. If you see more, something went very wrong.

---

## Step 2: Find Your iOS Device

```bash
xcrun xctrace list devices
```

Note your device UDID (the hex string in parentheses). Replace `<DEVICE_UDID>` in subsequent steps.

---

## Step 3: Export Xcode Project from Unity

Make sure no other Unity Editor instance has `unity_project` open (Unity doesn't share well with others):

```bash
/Applications/Unity/Hub/Editor/6000.3.11f1/Unity.app/Contents/MacOS/Unity \
  -batchmode -quit -nographics \
  -projectPath ./unity_project \
  -executeMethod BuildiOS.Build \
  -logFile /tmp/unity_ios_build.log
```

Takes about 2-5 minutes. Watch progress:
```bash
tail -f /tmp/unity_ios_build.log
```

Success indicator: `Exiting batchmode successfully now!` at the end of the log. If you see anything else, it didn't exit successfully, and neither will your good mood.

> For Development builds (with debugging support), replace `BuildiOS.Build` with `BuildiOS.BuildDevelopment`.

---

## Step 4: Build with Xcode

```bash
xcodebuild \
  -project unity_project/Builds/iOS/Unity-iPhone.xcodeproj \
  -scheme Unity-iPhone \
  -destination "platform=iOS,id=<DEVICE_UDID>" \
  -configuration Debug \
  -allowProvisioningUpdates \
  build 2>&1 | tee /tmp/xcode_build.log
```

Takes about 2-5 minutes. Success indicator: `** BUILD SUCCEEDED **`

If code signing fails (it will, at least once — it's a rite of passage), open the project in Xcode and set the Team manually:
```bash
open unity_project/Builds/iOS/Unity-iPhone.xcodeproj
```
Go to Signing & Capabilities, select your developer Team, then re-run the command above.

---

## Step 5: Install on Device

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "AreaTargetTest.app" \
  -path "*/Debug-iphoneos/*" | head -1)

xcrun devicectl device install app \
  --device <DEVICE_UDID> "$APP_PATH"
```

---

## Step 6: Launch the App

```bash
xcrun devicectl device process launch \
  --device <DEVICE_UDID> com.areatarget.test
```

---

## What to Look For During Testing

After launch, the app enters ARTestScene. Here's what you'll see on screen:

1. **Status bar**: Initializing → Localizing → Tracking / Lost
2. **Debug panel** (trackingInfoText):
   - Confidence: match confidence percentage
   - Features: matched feature count for current frame
   - Frames: total processed frames
   - Mode: Raw (initial) → Aligned (after AT computation)
   - Quality: NONE → RECOGNIZED → LOCALIZED
   - AKAZE: Triggered / Not triggered (only fires when ORB gives up)
   - Consistency: Passed / Rejected
3. **Quality indicator** (qualityText):
   - 🔴 Red = NONE (not recognized — the room is a stranger)
   - 🟡 Yellow = RECOGNIZED (Raw mode match found)
   - 🟢 Green = LOCALIZED (Aligned mode, high-accuracy pose — the good stuff)
4. **3D content**: Blue cube + RGB axes, overlaid on the real scene when tracking succeeds

### Expected Normal Flow

1. Launch → "Initialization complete, localizing..."
2. Point at the scanned area → Quality changes from NONE to RECOGNIZED (yellow)
3. Sustained tracking for 10+ frames → Quality becomes LOCALIZED (green), Mode switches from Raw to Aligned
4. 3D cube stably overlaid on the scene (if it's floating in mid-air, something went wrong — or you scanned a very unusual room)

### Troubleshooting

| Symptom | Likely Cause |
|---------|-------------|
| "Asset directory not found: SLAMTestAssets" | SLAMTestAssets directory missing from StreamingAssets |
| "Missing features.db" | features.db not included in build |
| Stuck on NONE forever | Not pointing at the scanned area, or features.db doesn't match the environment. Try pointing at something you actually scanned. |
| AKAZE triggers frequently | ORB struggling (major lighting changes or large viewpoint differences). Not a bug, just ORB being dramatic. |
| Consistency frequently rejects | Localization results are unstable, may need more feature points or a better scan |

---

## Viewing Device Logs

```bash
# Real-time app logs (filtered to ARTestScene)
xcrun devicectl device info log --device <DEVICE_UDID> 2>&1 | grep "ARTestScene"
```

---

## Quick Rebuild Workflow (after code changes)

- Changed only C# code (no native library changes): Skip Step 1, start from Step 3
- Changed C++ native code: Start from Step 1 (the full tour)
- Changed nothing but want to rebuild anyway: Seek help. Or just start from Step 3, we don't judge.
