import XCTest
@testable import AreaTargetScanner

final class LocalizationWorkflowTests: XCTestCase {
    func testNewAreaTargetJournalRetainsSourceIdentityAndOldJournalDecodes() throws {
        let job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: "/scan",
                                          displayName: "Scan", createdAt: Date())
        try sourceRoundTrip(job)
        XCTAssertEqual(try JSONDecoder().decode(AreaTargetProcessingJob.self, from: JSONEncoder().encode(job)), job)
    }
    func testAreaTargetJournalRetainsClientPreparationAndLegacyRemainsUnknown() throws {
        let job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: "/scan",
                                          displayName: "Scan", createdAt: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        let preparation: [String: Any] = ["schemaVersion": 1, "policy": "mobile-scan-preparation-v1",
            "policyVersion": 1, "profile": "fast", "preparedBy": "client", "originalFrameCount": 100,
            "selectedFrameCount": 80, "selectedIndices": (0..<80).map { $0 * 99 / 79 },
            "processedPixelCount": 153_600_000, "resizedFrameCount": 80,
            "maximumOutputLongEdge": 1600, "scaleDigest": String(repeating: "a", count: 64)]
        json["clientPreparation"] = preparation
        let decoded = try JSONDecoder().decode(AreaTargetProcessingJob.self, from: JSONSerialization.data(withJSONObject: json))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let restored = try XCTUnwrap(stored["clientPreparation"] as? [String: Any])
        XCTAssertEqual(restored["originalFrameCount"] as? Int, 100)
        XCTAssertEqual(restored["scaleDigest"] as? String, preparation["scaleDigest"] as? String)
        XCTAssertNil((try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])?["clientPreparation"])
    }

    func testNewImmersalJournalRetainsSourceIdentityAndOldJournalDecodes() throws {
        let job = ImmersalMappingJob(id: UUID(), userID: 1, scanName: "scan", mapName: "map", createdAt: Date())
        try sourceRoundTrip(job)
        XCTAssertEqual(try JSONDecoder().decode(ImmersalMappingJob.self, from: JSONEncoder().encode(job)), job)
    }
    @MainActor
    func testComparisonEntryRejectsUnknownOrDifferentSourceAssets() {
        var area = pairedAreaJob()
        var job = pairedImmersalJob(createdAt: Date())
        XCTAssertNotNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        job.sourceFingerprint = nil
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        job.sourceFingerprint = String(repeating: "b", count: 64)
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        area.sourceFingerprint = nil
        job.sourceFingerprint = nil
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]), "Two legacy unknown sources must not be considered the same capture")
    }
    @MainActor
    func testComparisonEntryRequiresDownloadedAreaAssetAndFinishedImmersalMap() {
        var area = pairedAreaJob()
        var job = pairedImmersalJob(createdAt: Date())
        area.savedAsset = nil
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        area = pairedAreaJob(); area.phase = .ready
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        area = pairedAreaJob(); job.mapID = nil
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
        job = pairedImmersalJob(createdAt: Date()); job.phase = .constructing
        XCTAssertNil(ScannerWorkspace.comparisonJob(for: area, in: [job]))
    }
    @MainActor
    func testComparisonEntrySelectsNewestCompletedMatchingCapture() {
        let old = pairedImmersalJob(createdAt: Date(timeIntervalSince1970: 1))
        let newest = pairedImmersalJob(createdAt: Date(timeIntervalSince1970: 2))
        var changed = pairedImmersalJob(createdAt: Date(timeIntervalSince1970: 3))
        changed.sourceFingerprint = String(repeating: "b", count: 64)
        var pending = pairedImmersalJob(createdAt: Date(timeIntervalSince1970: 4))
        pending.phase = .constructing
        XCTAssertEqual(ScannerWorkspace.comparisonJob(for: pairedAreaJob(), in: [changed,old,pending,newest])?.id, newest.id)
    }
    private func pairedAreaJob() -> AreaTargetProcessingJob {
        let id = UUID().uuidString.lowercased()
        let root = URL(fileURLWithPath: "/synthetic-navigation")
        var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: root.path, displayName: "Navigation fixture", createdAt: Date())
        job.phase = .downloaded; job.sourceFingerprint = String(repeating: "a", count: 64)
        job.savedAsset = AreaTargetSavedAsset(jobID: id, bundleURL: root.appendingPathComponent("result.zip"), directoryURL: root,
            modelURL: root.appendingPathComponent("optimized.glb"), featuresURL: root.appendingPathComponent("features.db"),
            manifestURL: root.appendingPathComponent("manifest.json"), savedAt: Date())
        return job
    }
    private func pairedImmersalJob(createdAt: Date) -> ImmersalMappingJob {
        var job = ImmersalMappingJob(id: UUID(), userID: 1, scanName: "capture", mapName: "map", createdAt: createdAt)
        job.phase = .done; job.mapID = 42; job.sourceFingerprint = String(repeating: "a", count: 64)
        return job
    }
    private func sourceRoundTrip<T: Codable>(_ value: T) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String:Any])
        json["sourceFingerprint"] = String(repeating: "a", count: 64)
        let decoded = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String:Any])
        XCTAssertEqual(saved["sourceFingerprint"] as? String, json["sourceFingerprint"] as? String)
    }
}
