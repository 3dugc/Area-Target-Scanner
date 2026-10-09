# Area Target Scanner app icon

Created on 2026-10-05 with the built-in ImageGen tool. Creative Production guided the identity; Product Design grounded it in the existing native blue scanner UI.

The white scanner corners enclose a translucent spatial cube. Broad strokes and a simple silhouette communicate room capture and remain recognizable at launcher size. The blue background fills the square; iOS applies the outer corner mask.

## Production asset

- Asset: `ios_scanner/AreaTargetScanner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.
- Format: 1024 × 1024 opaque PNG, exported from the 1254 × 1254 generated original using macOS `sips`.
- Target: the existing `AppIcon` build setting for both Debug and Release, iPhone and iPad.
- Removed the unused `AccentColor` catalog setting, which referred to a missing asset. The existing system-blue interface retains its default tint.
- Source: `/Users/dirui/.codex/generated_images/01a10bd2-71e1-7962-81e9-18ef4e8c6947/exec-516ccb47-2e04-4fa3-b9dc-f96445072c7a.png`.
- Apple configuration reference: https://developer.apple.com/documentation/xcode/configuring-your-app-icon

## Generation prompt

Use case: logo-brand. Create ONE finished production-ready iOS app icon for Area Target Scanner, a professional LiDAR room scanning and 3D spatial localization utility. Square 1024x1024 opaque edge-to-edge image, no mockup. Visual idea: a single bold sculptural isometric cube formed from clean luminous white and pale icy-cyan edges, enclosed by four thick white scanner viewfinder corner brackets. The cube symbolizes capturing real three-dimensional spaces; subtle cyan translucent top and side facets give depth, but this must stay a clean iconic symbol readable at 40 px. Brackets form a balanced strong graphic with comfortably rounded stroke ends. Use a richly saturated electric-blue background, close to native iOS blue (#1675F8 to #0753C9), with a subtle controlled brighter blue illumination behind the central cube. The central white/cyan symbol occupies roughly 62 percent of the square, generous clear safe margins of at least 16 percent all around. Composition exactly centered, harmonious, architectural, precise, friendly premium utility identity. Very restrained dimensional lighting and crisp edges. No typography, no letters, no words, no numbers, no logos of other brands, no watermark, no camera illustration, no extra objects, no grid of tiny lines, no complex particle cloud, no hairlines. No pre-rounded exterior corners: the blue background fills all four corners and all edges of the square canvas, iOS supplies the final corner mask. Only one icon image, not a comparison sheet.

## Verification

- `sips` confirms the exported source is 1024 × 1024 and has no alpha channel. `plutil -lint` validates the Xcode project; resource references were independently reviewed.
- Xcode 27.0 Debug simulator build succeeded using the AreaTargetScanner scheme, iPhone 17 Pro / iOS 26.5, signing disabled. Final log: `/private/tmp/area-target-icon-build-final.log`. No asset-catalog warnings remain.
- The built app includes `Assets.car`, generated iPhone/iPad icon PNGs, and `AppIcon` in both `CFBundleIcons` and `CFBundleIcons~ipad`.
- Installed the final build on the simulator and inspected the actual launcher icon. Evidence: [simulator-home.png](simulator-home.png). Small-size export: [preview-180.png](preview-180.png).
- Initial 2026-10-05 verification used the simulator. On 2026-10-08 the signed App was installed and launched on the connected iPhone 15 Pro. `devicectl device info appIcon` returned a non-placeholder 1024×1024 icon from the installed bundle `com.areatarget.scanner`; its appearance matches this design. Evidence: [iPhone system-returned icon](iphone-icon-2026-10-08.png) and [installation/source record](../../validation/ios-phone-install-2026-10-08.json). The user reported a different desktop icon; direct desktop inspection is unavailable because iPhone Mirroring reports iCloud is not syncing. Desktop refresh remains to be confirmed by the user. App Store submission was not performed.
