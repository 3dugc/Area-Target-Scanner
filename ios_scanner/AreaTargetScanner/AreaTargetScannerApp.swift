import SwiftUI

/// Main entry point for the Area Target Scanner iOS app.
///
/// Uses ARKit + LiDAR to capture point clouds, RGB images, and camera poses
/// for downstream 3D reconstruction and AR localization.
@main
struct AreaTargetScannerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["AREA_TARGET_UNIT_TEST_HOST"] == "1" {
                // Hosted tests construct their own views and models. Do not
                // restore production tasks or start cloud monitoring here.
                Color.clear.accessibilityIdentifier("area-target-unit-test-host")
                    .onAppear {
                        // A hosted suite can outlast Auto-Lock. This flag is
                        // process-local and absent from normal app launches.
                        UIApplication.shared.isIdleTimerDisabled = true
                        print("AREA_TARGET_TEST_HOST idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)")
                    }
                    .onChange(of: scenePhase) { phase in
                        print("AREA_TARGET_TEST_HOST scenePhase=\(phase)")
                    }
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
