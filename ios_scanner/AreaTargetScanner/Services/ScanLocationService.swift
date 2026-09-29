import Foundation
import CoreLocation

protocol ScanLocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var delegate: CLLocationManagerDelegate? { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: ScanLocationManaging {}

@MainActor
final class ScanLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = "GPS 未开启"
    let store: ScanLocationStore
    private let manager: ScanLocationManaging
    private var scanning = false
    private var appActive = true
    private var updating = false

    var hasUsableLocation: Bool { store.snapshot(at: Date().timeIntervalSince1970) != nil }

    init(manager: ScanLocationManaging = CLLocationManager(), store: ScanLocationStore = ScanLocationStore()) {
        self.manager = manager
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        scanning = true
        store.clear()
        if manager.authorizationStatus == .notDetermined {
            status = "GPS 等待授权"
            manager.requestWhenInUseAuthorization()
        } else { refreshAuthorization() }
    }

    func stop() {
        scanning = false
        stopUpdates()
        status = "GPS 未开启"
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        refreshAuthorization()
    }

    func refreshAuthorization() {
        guard scanning, appActive else { stopUpdates(); return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !updating { manager.startUpdatingLocation(); updating = true }
            refreshStatus()
        case .denied, .restricted:
            stopUpdates()
            status = "GPS 未授权 · 导出位置为 0"
        case .notDetermined:
            status = "GPS 等待授权"
        @unknown default:
            stopUpdates()
            status = "GPS 不可用 · 导出位置为 0"
        }
    }

    func refreshStatus() {
        guard scanning, updating else { return }
        status = hasUsableLocation ? "GPS 可用" : "GPS 定位中 · 无有效定位时导出 0"
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        updating = false
        store.clear()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refreshAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { fix in
            ScanLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                         altitude: fix.altitude, timestamp: fix.timestamp.timeIntervalSince1970,
                         horizontalAccuracy: fix.horizontalAccuracy, verticalAccuracy: fix.verticalAccuracy)
        }
        Task { @MainActor [weak self] in
            guard let self, self.scanning, self.appActive, self.updating else { return }
            for fix in fixes { self.store.append(fix) }
            self.refreshStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.scanning, self.appActive else { return }
            self.store.clear()
            self.status = "GPS 暂不可用 · 导出位置为 0"
        }
    }
}
