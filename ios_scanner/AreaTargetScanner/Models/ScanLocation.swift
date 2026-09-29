import Foundation

/// A capture-time fix. Timestamp is Unix time, unlike the frame's relative timestamp.
struct ScanLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double

    func validated(at captureTime: TimeInterval) -> ScanLocation? {
        guard captureTime.isFinite, timestamp.isFinite,
              (0...15).contains(captureTime - timestamp),
              latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude),
              horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else { return nil }
        let validAltitude = altitude.isFinite && verticalAccuracy.isFinite && verticalAccuracy >= 0
        return ScanLocation(latitude: latitude, longitude: longitude,
                            altitude: validAltitude ? altitude : 0, timestamp: timestamp,
                            horizontalAccuracy: horizontalAccuracy,
                            verticalAccuracy: validAltitude ? verticalAccuracy : -1)
    }
}

/// Bridges main-thread Core Location callbacks to the ARKit capture queue.
final class ScanLocationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var fixes: [ScanLocation] = []

    func append(_ fix: ScanLocation) {
        lock.lock(); defer { lock.unlock() }
        fixes.append(fix)
        fixes.sort { $0.timestamp < $1.timestamp }
        if fixes.count > 32 { fixes.removeFirst(fixes.count - 32) }
    }

    func snapshot(at timestamp: TimeInterval) -> ScanLocation? {
        lock.lock(); defer { lock.unlock() }
        return fixes.reversed().compactMap { $0.validated(at: timestamp) }.first
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        fixes.removeAll()
    }
}

/// Keeps separate coordinate priors for uninterrupted tracking segments.
final class ScanTrackingRunState {
    private let lock = NSLock()
    private let makeRun: () -> Int
    private var run = 0
    private var hasTracked = false
    private var needsNewRun = false

    init(makeRun: @escaping () -> Int = { Int.random(in: 1...Int(Int32.max)) }) {
        self.makeRun = makeRun
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        run = nextRun()
        hasTracked = false
        needsNewRun = false
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        if hasTracked { needsNewRun = true }
    }

    func runForFrame(isTrackingNormal: Bool) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard isTrackingNormal else {
            if hasTracked { needsNewRun = true }
            return nil
        }
        if run == 0 || needsNewRun { run = nextRun() }
        needsNewRun = false
        hasTracked = true
        return run
    }

    private func nextRun() -> Int {
        let candidate = max(1, min(Int(Int32.max), makeRun()))
        return candidate == run ? (run == Int(Int32.max) ? 1 : run + 1) : candidate
    }
}
