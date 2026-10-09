# Immersal native iOS runtime

Source: https://github.com/immersal/imdk-unity
Pinned commit: `6fd5c0bf42c86c35c97630c84df4438388e7f7c8` (package 2.4.0).
Artifact: `Runtime/Plugins/iOS/libPosePlugin.a`, device arm64 only.
SHA256: `45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f`.

Restore the local binary after cloning, from the repository root:

```sh
python3 tools/ios/bootstrap_immersal_sdk.py
```

The standard-library-only script downloads this exact commit's artifact from the
official `immersal/imdk-unity` GitHub repository. It verifies SHA256 before
publishing the file atomically at the path used by Xcode. Existing matching bytes
are reused without network access; different bytes, symlinks and directories are
rejected without overwrite. Interrupted or invalid downloads leave no SDK file.
An optional `--destination /absolute/local/path/libPosePlugin.a` changes only the
local output path, never the upstream pin or expected hash. The script does not
build, install an app, accept SDK terms, stage files or modify signing settings.

Keep `libPosePlugin.a` out of Git and distribution archives. Keep this README,
`ImmersalNative.h` and `ThirdPartyNotices.md` in source control; the binary is a
local development dependency restored separately. Verify the offline download
and cache contracts without fetching the real SDK:

```sh
python3 tools/ios/test_bootstrap_immersal_sdk.py
```

`ImmersalNative.h` describes the C ABI from that commit's `Runtime/Scripts/Core.cs`.
The older native iOS sample header omits the final `double rmse`; it must not be used
with this binary. The result has size 48 and rmse offset 40 on arm64.
Link only for iphoneos, with libc++ and Security. Simulator reports unsupported.

The SDK is proprietary, not covered by the native sample's MIT license. The
upstream Core.cs notice states Copyright (C) 2024 Immersal - Part of Hexagon,
All Rights Reserved, and restricts commercial copying/distribution or making
available to third parties without written permission of Immersal Ltd.
See https://developers.immersal.com/ for applicable account/SDK terms and contact
sales@immersal.com for commercial licensing. Retain the accompanying upstream
ThirdPartyNotices.md. This integration is for the user's device development test;
no distribution or license acceptance has been performed by this task.
