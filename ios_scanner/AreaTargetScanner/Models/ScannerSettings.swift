import Foundation
import Combine

@MainActor
final class ScannerSettings: ObservableObject {
    static let shared = ScannerSettings()

    private enum PreferenceKey {
        static let processingProfile = "scanner.settings.areaTarget.profile"
        static let uvUnwrap = "scanner.settings.areaTarget.uvUnwrap"
    }

    private let preferences: UserDefaults?

    @Published var processingProfile: AreaTargetProcessingProfile {
        didSet { preferences?.set(processingProfile.rawValue, forKey: PreferenceKey.processingProfile) }
    }

    @Published var uvUnwrap: Bool {
        didSet { preferences?.set(uvUnwrap, forKey: PreferenceKey.uvUnwrap) }
    }

    init(preferences: UserDefaults? = .standard) {
        self.preferences = preferences
        let storedProfile = preferences?.string(forKey: PreferenceKey.processingProfile)
        processingProfile = storedProfile.flatMap(AreaTargetProcessingProfile.init(rawValue:)) ?? .quality
        uvUnwrap = preferences?.object(forKey: PreferenceKey.uvUnwrap) as? Bool ?? true
    }

    func resetToDefaults() {
        processingProfile = .quality
        uvUnwrap = true
    }
}
