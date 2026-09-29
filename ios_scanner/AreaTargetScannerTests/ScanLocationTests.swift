import XCTest
import CoreLocation
@testable import AreaTargetScanner

final class ScanLocationTests: XCTestCase {
    func testSnapshotRejectsStaleFutureAndInvalidCoordinates() {
        let fix = ScanLocation(latitude: 30, longitude: 120, altitude: 20,
                               timestamp: 100, horizontalAccuracy: 5, verticalAccuracy: 3)
        XCTAssertNotNil(fix.validated(at: 115))
        XCTAssertNil(fix.validated(at: 115.01))
        XCTAssertNil(fix.validated(at: 99))
        XCTAssertNil(ScanLocation(latitude: 91, longitude: 120, altitude: 20,
                                  timestamp: 100, horizontalAccuracy: 5, verticalAccuracy: 3).validated(at: 101))
        XCTAssertNil(ScanLocation(latitude: 30, longitude: 120, altitude: 20,
                                  timestamp: 100, horizontalAccuracy: -1, verticalAccuracy: 3).validated(at: 101))
    }

    func testInvalidAltitudeKeepsHorizontalFix() throws {
        let fix = ScanLocation(latitude: 30, longitude: 120, altitude: 900,
                               timestamp: 100, horizontalAccuracy: 5, verticalAccuracy: -1)
        let valid = try XCTUnwrap(fix.validated(at: 101))
        XCTAssertEqual(valid.latitude, 30)
        XCTAssertEqual(valid.longitude, 120)
        XCTAssertEqual(valid.altitude, 0)
    }

    func testStoreSelectsLatestFixAtCaptureTimeAndCanBeCleared() {
        let store = ScanLocationStore()
        for time in [100.0, 108.0, 120.0] {
            store.append(ScanLocation(latitude: time / 10, longitude: 120, altitude: 2,
                                      timestamp: time, horizontalAccuracy: 1, verticalAccuracy: 1))
        }
        XCTAssertEqual(store.snapshot(at: 110)?.timestamp, 108)
        XCTAssertNil(store.snapshot(at: 136))
        store.clear()
        XCTAssertNil(store.snapshot(at: 110))
    }

    func testRunIsStableWithinTrackingSegmentAndChangesAfterLoss() {
        var next = 40
        let state = ScanTrackingRunState(makeRun: { next += 1; return next })
        state.start()
        let first = state.runForFrame(isTrackingNormal: true)
        XCTAssertEqual(first, 41)
        XCTAssertEqual(state.runForFrame(isTrackingNormal: true), first)
        XCTAssertNil(state.runForFrame(isTrackingNormal: false))
        XCTAssertNil(state.runForFrame(isTrackingNormal: false))
        XCTAssertEqual(state.runForFrame(isTrackingNormal: true), 42)
        state.interrupt()
        XCTAssertEqual(state.runForFrame(isTrackingNormal: true), 43)
        state.start()
        XCTAssertEqual(state.runForFrame(isTrackingNormal: true), 44)
    }
}

@MainActor
final class ScanLocationServiceTests: XCTestCase {
    func testDeniedPermissionDoesNotStartGPS() {
        let manager = FakeLocationManager(status: .denied)
        let service = ScanLocationService(manager: manager)
        service.start()
        XCTAssertEqual(manager.starts, 0)
        XCTAssertEqual(manager.requests, 0)
        XCTAssertFalse(service.hasUsableLocation)
    }

    func testLocationCallbacksFailureAndStoppedService() async throws {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let service = ScanLocationService(manager: manager)
        let callbackManager = CLLocationManager()
        service.start()
        XCTAssertFalse(service.hasUsableLocation) // authorized but no signal
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31, longitude: 121),
                             altitude: 12, horizontalAccuracy: 3, verticalAccuracy: 5, timestamp: Date())
        service.locationManager(callbackManager, didUpdateLocations: [fix])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(service.hasUsableLocation)
        service.locationManager(callbackManager, didFailWithError: NSError(domain: kCLErrorDomain, code: 0))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(service.hasUsableLocation)
        service.stop()
        service.locationManager(callbackManager, didUpdateLocations: [fix])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(service.hasUsableLocation)
    }

    func testAuthorizationAndBackgroundLifecycle() {
        let manager = FakeLocationManager(status: .notDetermined)
        let service = ScanLocationService(manager: manager)
        service.start()
        XCTAssertEqual(manager.requests, 1)
        manager.authorizationStatus = .authorizedWhenInUse
        service.refreshAuthorization()
        XCTAssertEqual(manager.starts, 1)
        service.setAppActive(false)
        XCTAssertGreaterThan(manager.stops, 0)
        service.setAppActive(true)
        XCTAssertEqual(manager.starts, 2)
        service.stop()
        service.setAppActive(true)
        XCTAssertEqual(manager.starts, 2)
    }
}

private final class FakeLocationManager: ScanLocationManaging {
    var authorizationStatus: CLAuthorizationStatus
    var desiredAccuracy: CLLocationAccuracy = 0
    weak var delegate: CLLocationManagerDelegate?
    var starts = 0
    var stops = 0
    var requests = 0
    init(status: CLAuthorizationStatus) { authorizationStatus = status }
    func requestWhenInUseAuthorization() { requests += 1 }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
}
