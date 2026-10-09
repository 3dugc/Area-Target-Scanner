import XCTest
import simd
@testable import AreaTargetScanner

@MainActor
final class ImmersalMapTestModelTests: XCTestCase {
    private var root: URL!
    private var store: ImmersalMapStore!
    private var api: MapTestGatedDownloader!
    private var credentials: MapTestMemoryCredentials!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersalMapTestModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImmersalMapStore(rootURL: root)
        api = MapTestGatedDownloader()
        credentials = MapTestMemoryCredentials()
    }

    override func tearDownWithError() throws {
        api.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }

    func testCachedMapRestoresOfflineWithoutReadingCredentialsOrDownloading() async throws {
        let bytes = Data([1, 2, 3, 4])
        let url = try store.save(data: bytes, userID: 7, mapID: 123)
        credentials.value = nil
        credentials.readError = CocoaError(.fileReadNoPermission)
        let vm = model()
        await waitUntil { !vm.isRestoring }
        XCTAssertEqual(vm.mapURL, url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(vm.mapURL)), bytes)
        XCTAssertNil(vm.savedReport, "A cached map without field tests must not invent a quality report")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isDownloading)
        vm.restore()
        await waitUntil { !vm.isRestoring }
        XCTAssertEqual(vm.mapURL, url)
        XCTAssertEqual(credentials.loadCount, 0, "Offline restoration must work even when login storage is unavailable")
        XCTAssertTrue(api.requests.isEmpty)
    }

    func testCancelledDownloadDoesNotSaveDelayedResponse() async throws {
        let vm = model()
        await waitUntil { !vm.isRestoring }
        vm.download()
        await waitUntil { self.api.requests.count == 1 }
        XCTAssertTrue(vm.isDownloading)
        XCTAssertEqual(api.requests.first?.mapID, 123)
        XCTAssertEqual(api.requests.first?.token, "offline-token")
        vm.cancelDownload()
        XCTAssertFalse(vm.isDownloading)
        api.release(request: 0, data: Data([9, 8, 7]))
        await drainReturnedRequests(1)
        XCTAssertNil(vm.mapURL)
        XCTAssertNil(try store.mapURL(userID: 7, mapID: 123))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertNil(vm.errorMessage, "User cancellation must not become a download error after the late result")
    }

    func testAccountChangeBeforeDelayedDownloadCompletesDoesNotSaveMap() async throws {
        let vm = model()
        await waitUntil { !vm.isRestoring }
        vm.download()
        await waitUntil { self.api.requests.count == 1 }
        credentials.value = ImmersalCredential(email: "other@example.com", userID: 8, token: "other-token")
        api.release(request: 0, data: Data([9, 8, 7]))
        await waitUntil { !vm.isDownloading }
        XCTAssertNil(vm.mapURL)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(try store.mapURL(userID: 7, mapID: 123))
        XCTAssertNil(try store.mapURL(userID: 8, mapID: 123))
        XCTAssertEqual(credentials.loadCount, 2, "The account must be checked again before any cache is published")
    }

    func testLogoutOrCredentialReplacementRejectsDelayedDownloadForSameMap() async throws {
        for replacement in [nil, ImmersalCredential(email: "scanner@example.com", userID: 7, token: "replacement-token")] {
            let localAPI = MapTestGatedDownloader()
            let localCredentials = MapTestMemoryCredentials()
            let vm = ImmersalMapTestModel(mapID: 123, userID: 7, api: localAPI, store: store,
                                          credentials: localCredentials)
            defer { vm.cancelDownload(); localAPI.releaseAll() }
            await waitUntil { !vm.isRestoring }
            vm.download()
            await waitUntil { localAPI.requests.count == 1 }
            localCredentials.value = replacement
            localAPI.release(request: 0, data: Data([4, 5, 6]))
            await waitUntil { !vm.isDownloading }
            XCTAssertNil(vm.mapURL)
            XCTAssertNil(try store.mapURL(userID: 7, mapID: 123))
            XCTAssertNotNil(vm.errorMessage)
        }
    }

    func testLateCancelledResponseCannotReplaceNewDownloadOrFinishItsBusyState() async throws {
        let vm = model()
        await waitUntil { !vm.isRestoring }
        vm.download()
        await waitUntil { self.api.requests.count == 1 }
        vm.cancelDownload()
        vm.download()
        await waitUntil { self.api.requests.count == 2 }
        api.release(request: 0, data: Data([1]))
        await drainReturnedRequests(1)
        XCTAssertTrue(vm.isDownloading, "The cancelled generation must not finish the new download")
        XCTAssertNil(vm.mapURL)
        XCTAssertNil(try store.mapURL(userID: 7, mapID: 123))

        let currentBytes = Data([2, 3, 4])
        api.release(request: 1, data: currentBytes)
        await waitUntil { !vm.isDownloading }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(vm.mapURL)), currentBytes)
        XCTAssertEqual(try store.mapURL(userID: 7, mapID: 123), vm.mapURL)
        XCTAssertNil(vm.errorMessage)
    }

    func testSuccessfulDownloadPublishesVerifiedCacheAndSurvivesOfflineRelaunch() async throws {
        let vm = model()
        await waitUntil { !vm.isRestoring }
        vm.download()
        vm.download()
        await waitUntil { self.api.requests.count == 1 }
        let bytes = Data([4, 3, 2, 1])
        api.release(request: 0, data: bytes)
        await waitUntil { !vm.isDownloading }
        XCTAssertEqual(api.requests.count, 1, "Repeated taps must not start duplicate downloads")
        let url = try XCTUnwrap(vm.mapURL)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(vm.errorMessage)
        XCTAssertGreaterThanOrEqual(credentials.loadCount, 2)
        let readsAfterDownload = credentials.loadCount

        credentials.value = nil
        credentials.readError = CocoaError(.fileReadNoPermission)
        let restored = model()
        await waitUntil { !restored.isRestoring }
        XCTAssertEqual(restored.mapURL, url)
        XCTAssertEqual(credentials.loadCount, readsAfterDownload)
        XCTAssertEqual(api.requests.count, 1)
    }

    func testSavedMeasuredReportRestoresWithoutCredentialsOrNetwork() async throws {
        try store.save(data: Data([1, 2, 3]), userID: 7, mapID: 123)
        let vm = model()
        await waitUntil { !vm.isRestoring }
        let expected = measuredReport()
        vm.save(expected)
        XCTAssertEqual(vm.savedReport, expected)
        let reportURL = try XCTUnwrap(vm.reportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertEqual(try JSONDecoder().decode(ImmersalLocalizationQualityReport.self,
                                               from: Data(contentsOf: reportURL)), expected)

        credentials.value = nil
        credentials.readError = CocoaError(.fileReadNoPermission)
        let restored = model()
        await waitUntil { !restored.isRestoring }
        XCTAssertEqual(restored.savedReport, expected)
        XCTAssertEqual(restored.mapURL, vm.mapURL)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(credentials.loadCount, 0)
        XCTAssertTrue(api.requests.isEmpty)
    }

    func testEmptyOrWrongIdentityReportCannotReplaceMeasuredReport() async throws {
        try store.save(data: Data([1, 2, 3]), userID: 7, mapID: 123)
        let vm = model()
        await waitUntil { !vm.isRestoring }
        let expected = measuredReport()
        vm.save(expected)
        let original = try Data(contentsOf: XCTUnwrap(vm.reportURL))
        vm.save(nil)
        vm.save(ImmersalLocalizationQualityAccumulator().report(mapID: 123, userID: 7))
        vm.save(measuredReport(mapID: 124))
        vm.save(measuredReport(userID: 8))
        XCTAssertEqual(vm.savedReport, expected)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(vm.reportURL)), original)
        XCTAssertTrue(api.requests.isEmpty)
    }

    func testRestorationIgnoresReportForAnotherMapOrAccount() async throws {
        try store.save(data: Data([1, 2, 3]), userID: 7, mapID: 123)
        let vm = model()
        await waitUntil { !vm.isRestoring }
        let reportURL = try XCTUnwrap(vm.reportURL)
        for mismatched in [measuredReport(mapID: 124), measuredReport(userID: 8)] {
            try JSONEncoder().encode(mismatched).write(to: reportURL)
            vm.restore()
            await waitUntil { !vm.isRestoring }
            XCTAssertNil(vm.savedReport)
            XCTAssertNotNil(vm.mapURL)
        }
        XCTAssertEqual(credentials.loadCount, 0)
        XCTAssertTrue(api.requests.isEmpty)
    }

    private func model() -> ImmersalMapTestModel {
        ImmersalMapTestModel(mapID: 123, userID: 7, api: api, store: store, credentials: credentials)
    }

    private func measuredReport(mapID: Int = 123, userID: Int = 7) -> ImmersalLocalizationQualityReport {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: false, elapsed: 0, latency: 1)
        accumulator.record(success: true, elapsed: 3, latency: 0.5,
                           worldFromMap: matrix_identity_float4x4, cameraPosition: SIMD3(0, 0, 0))
        accumulator.record(success: true, elapsed: 6, latency: 0.8,
                           worldFromMap: matrix_identity_float4x4, cameraPosition: SIMD3(1, 0, 0))
        return accumulator.report(mapID: mapID, userID: userID, date: Date(timeIntervalSince1970: 1_790_730_960))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The controlled asynchronous operation did not reach the expected state", file: file, line: line)
    }

    private func drainReturnedRequests(_ count: Int) async {
        await waitUntil { self.api.returnedCount >= count }
        // The fake deliberately ignores cancellation, like an already-completed
        // network response. Let its caller run the cancellation/generation checks.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private final class MapTestGatedDownloader: ImmersalMapDownloading {
    struct Request {
        let mapID: Int
        let token: String
    }
    private(set) var requests: [Request] = []
    private(set) var returnedCount = 0
    private var continuations: [Int: CheckedContinuation<Data, Never>] = [:]

    func downloadMap(mapID: Int, token: String) async throws -> Data {
        let index = requests.count
        requests.append(Request(mapID: mapID, token: token))
        let data = await withCheckedContinuation { continuations[index] = $0 }
        returnedCount += 1
        return data
    }

    func release(request: Int, data: Data) {
        continuations.removeValue(forKey: request)?.resume(returning: data)
    }

    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: Data([0])) }
    }
}

private final class MapTestMemoryCredentials: ImmersalCredentialStoring {
    var value: ImmersalCredential? = ImmersalCredential(email: "scanner@example.com", userID: 7, token: "offline-token")
    var readError: Error?
    private(set) var loadCount = 0

    func load() throws -> ImmersalCredential? {
        loadCount += 1
        if let readError { throw readError }
        return value
    }
    func save(_ credential: ImmersalCredential) throws { value = credential }
    func clear() throws { value = nil }
}
