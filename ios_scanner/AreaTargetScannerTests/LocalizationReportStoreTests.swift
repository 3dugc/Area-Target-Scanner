import XCTest
import simd
@testable import AreaTargetScanner

final class LocalizationReportStoreTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("localization-reports-" + UUID().uuidString,isDirectory:true) }
    private func report(provider:LocalizationProvider = .areaTarget, asset:String = "asset-a", source:String = String(repeating:"a",count:64), date:TimeInterval = 1, mode:LocalizationTimingMode = .live) -> LocalizationEvaluationReport {
        LocalizationEvaluationAccumulator(identity:.init(provider:provider,assetID:asset,sourceFingerprint:source,engineVersion:"1"),timingMode:mode)
            .report(date:Date(timeIntervalSince1970:date))
    }
    func testSaveRestoreAndSortedKeyAtomicJSON() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let original = report()
        let url = try store.save(report:original)
        XCTAssertNotNil(UUID(uuidString:url.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try LocalizationReportStore(rootDirectory:directory).latest(identity:original.identity),original)
        XCTAssertEqual(try store.latestURL(identity:original.identity),url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(object["schemaVersion"] as? Int,1)
        let raw = try String(contentsOf:url,encoding:.utf8)
        XCTAssertLessThan(try XCTUnwrap(raw.range(of:"\"id\"")).lowerBound,try XCTUnwrap(raw.range(of:"\"report\"")).lowerBound)
        XCTAssertFalse(raw.contains("token")); XCTAssertFalse(raw.contains("GPS")); XCTAssertFalse(raw.contains("pixels"))
    }
    func testSaveInsideApplicationSupportWithMissingParentDirectories() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReportSandboxRegression-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalizationReportStore(rootDirectory: directory.appendingPathComponent("nested/cache", isDirectory: true))
        let original = report()
        XCTAssertNil(try store.latest(identity: original.identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let url = try store.save(report: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.latest(identity: original.identity), original)
    }
    func testMissingParentReplacedBySymlinkIsRejected() throws {
        let directory = root(), outside = root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let parent = directory.appendingPathComponent("parent", isDirectory: true)
        let store = LocalizationReportStore(rootDirectory: parent.appendingPathComponent("cache", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        XCTAssertThrowsError(try store.save(report: report()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testIdentityIsolationAndUntrustedFingerprintNeverBecomesPath() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let area = report(source:"../../outside"); let immersal = report(provider:.immersal)
        _ = try store.save(report:area); _ = try store.save(report:immersal)
        XCTAssertEqual(try store.latest(identity:area.identity),area)
        XCTAssertEqual(try store.latest(identity:immersal.identity),immersal)
        XCTAssertNil(try store.latest(identity:report(asset:"other").identity))
    }
    func testCorruptUnknownSchemaAndOversizeRecordsDoNotHideValidReports() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let older = report(date:1); _ = try store.save(report:older)
        let corrupt = try store.save(report:report(date:2)); try Data("broken".utf8).write(to:corrupt)
        let unknown = try store.save(report:report(date:3))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:unknown)) as? [String:Any]); json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject:json).write(to:unknown)
        let huge = unknown.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Data(repeating:32,count:1024*1024+1).write(to:huge)
        XCTAssertEqual(try store.latest(identity:older.identity),older)
    }
    func testRejectsOversizeSaveAndRootSymlink() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        XCTAssertThrowsError(try store.save(report:report(asset:String(repeating:"x",count:1024*1024))))
        let target = root(); defer { if FileManager.default.fileExists(atPath:target.path) { try? FileManager.default.removeItem(at:target) } }
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:target)
        XCTAssertThrowsError(try store.save(report:report()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:target.path).isEmpty)
    }
    func testSymlinkRecordIsSkippedWithoutReadingOutsideRoot() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory); let original = report()
        let valid = try store.save(report:original)
        let link = valid.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:valid)
        XCTAssertEqual(try store.latest(identity:original.identity),original)
    }
    func testHistoryRetainsAtMostTwoHundredIndependentFiles() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        var latestURL:URL?
        for index in 0..<205 { latestURL = try store.save(report:report(date:Double(index))) }
        let files = try FileManager.default.contentsOfDirectory(at:try XCTUnwrap(latestURL).deletingLastPathComponent(),includingPropertiesForKeys:nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count,200)
        XCTAssertEqual(try store.latest(identity:report().identity)?.date,Date(timeIntervalSince1970:204))
    }
    func testComparisonSaveRestoreSchemaAndSourceIsolation() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let comparison = LocalizationComparisonReport(id:UUID(),date:Date(timeIntervalSince1970:5),queryFingerprint:String(repeating:"b",count:64),sourceFingerprint:String(repeating:"a",count:64),executionOrder:[.areaTarget,.immersal],results:[report(mode:.recordedReplay),report(provider:.immersal,mode:.recordedReplay)])
        let url = try store.save(comparison:comparison)
        let restored = try XCTUnwrap(store.latestComparison(sourceFingerprint:String(repeating:"a",count:64)))
        XCTAssertEqual(restored.id,comparison.id)
        XCTAssertEqual(try store.latestComparisonURL(sourceFingerprint:String(repeating:"a",count:64)),url)
        XCTAssertEqual(restored.results,comparison.results)
        XCTAssertNil(try store.latestComparison(sourceFingerprint:"other-scan"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]); json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        XCTAssertNil(try store.latestComparison(sourceFingerprint:String(repeating:"a",count:64)))
    }
    func testSaveAndRestoreRejectSemanticallyCorruptedReports() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let original = sufficientReport(provider:.areaTarget)
        let validURL = try store.save(report:original)
        let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:validURL)) as? [String:Any])
        for changes:[String:Any] in [["attemptCount":0,"successCount":0,"eligibility":"eligible","score":100],
                                    ["successRate":0.5],["successCount":21],["captureDuration":-1],
                                    ["score":99],["firstRecognitionCaptureOffset":100],
                                    ["medianTranslationDeltaMeters":1,"p95TranslationDeltaMeters":0]] {
            var reportObject = try XCTUnwrap(validObject["report"] as? [String:Any])
            for (key,value) in changes { reportObject[key] = value }
            let encoded = try JSONSerialization.data(withJSONObject:reportObject)
            let invalid = try JSONDecoder().decode(LocalizationEvaluationReport.self,from:encoded)
            XCTAssertThrowsError(try store.save(report:invalid),String(describing:changes))
            var envelope = validObject; envelope["report"] = reportObject
            try JSONSerialization.data(withJSONObject:envelope).write(to:validURL)
            XCTAssertNil(try store.latest(identity:original.identity),String(describing:changes))
            XCTAssertNil(try store.latestURL(identity:original.identity))
        }
    }
    func testComparisonRejectsDuplicateProvidersSourceOrderAndDenominatorMismatch() throws {
        let directory = root(); defer { if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) } }
        let store = LocalizationReportStore(rootDirectory:directory)
        let first = sufficientReport(provider:.areaTarget,mode:.recordedReplay)
        let second = sufficientReport(provider:.immersal,mode:.recordedReplay)
        let source = String(repeating:"a",count:64), query = String(repeating:"b",count:64)
        let invalids = [
            LocalizationComparisonReport(id:UUID(),date:Date(),queryFingerprint:query,sourceFingerprint:source,executionOrder:[.areaTarget,.immersal],results:[first,first]),
            LocalizationComparisonReport(id:UUID(),date:Date(),queryFingerprint:query,sourceFingerprint:String(repeating:"c",count:64),executionOrder:[.areaTarget,.immersal],results:[first,second]),
            LocalizationComparisonReport(id:UUID(),date:Date(),queryFingerprint:query,sourceFingerprint:source,executionOrder:[.immersal,.areaTarget],results:[first,second]),
            LocalizationComparisonReport(id:UUID(),date:Date(),queryFingerprint:query,sourceFingerprint:source,executionOrder:[.areaTarget,.immersal],results:[first,sufficientReport(provider:.immersal,count:19,mode:.recordedReplay)])
        ]
        for invalid in invalids { XCTAssertThrowsError(try store.save(comparison:invalid)) }
    }
    func testExactAssetHistoryDoesNotLetNewerOtherMapHideMatchingPair() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalizationReportStore(rootDirectory: directory)
        let source = String(repeating: "a", count: 64)
        let original = LocalizationComparisonReport(id: UUID(), date: Date(timeIntervalSince1970: 1), queryFingerprint: String(repeating: "b", count: 64), sourceFingerprint: source,
            executionOrder: [.areaTarget,.immersal], results: [report(mode: .recordedReplay),report(provider: .immersal, mode: .recordedReplay)])
        let newer = LocalizationComparisonReport(id: UUID(), date: Date(timeIntervalSince1970: 2), queryFingerprint: String(repeating: "c", count: 64), sourceFingerprint: source,
            executionOrder: [.areaTarget,.immersal], results: [report(asset: "rebuilt",mode: .recordedReplay),report(provider: .immersal, mode: .recordedReplay)])
        let url = try store.save(comparison: original); _ = try store.save(comparison: newer)
        XCTAssertEqual(try store.latestComparison(identities: original.results.map(\.identity))?.id, original.id)
        XCTAssertEqual(try store.latestComparisonURL(identities: original.results.map(\.identity)), url)
        let markdown = try store.saveMarkdown(comparison: original)
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("Area Target"))
    }
    func testLegacyComparisonDecodeKeepsOptionalEvidenceAbsent() throws {
        let legacy = LocalizationComparisonReport(id: UUID(), date: Date(), queryFingerprint: String(repeating: "b", count: 64), sourceFingerprint: String(repeating: "a", count: 64),
            executionOrder: [.areaTarget,.immersal], results: [report(mode: .recordedReplay),report(provider: .immersal,mode: .recordedReplay)])
        let restored = try JSONDecoder().decode(LocalizationComparisonReport.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(restored.attempts); XCTAssertNil(restored.recording); XCTAssertNil(restored.analysis)
        XCTAssertEqual(restored.results, legacy.results)
    }
    private func sufficientReport(provider:LocalizationProvider,count:Int = 20,mode:LocalizationTimingMode = .live) -> LocalizationEvaluationReport {
        var value = LocalizationEvaluationAccumulator(identity:.init(provider:provider,assetID:"asset-a",sourceFingerprint:String(repeating:"a",count:64),engineVersion:"1"),timingMode:mode)
        for index in 0..<count {
            _ = value.record(sequence:index,captureTime:Double(index)*2,latency:1,cameraPosition:SIMD3(Float(index)*0.2,0,0),worldFromScan:matrix_identity_float4x4,commonAlignmentValid:true)
        }
        return value.report(date:Date(timeIntervalSince1970:1))
    }
    func testMissingStoreReturnsNilWithoutCreatingDirectories() throws {
        let directory = root(); let store = LocalizationReportStore(rootDirectory:directory)
        XCTAssertNil(try store.latest(identity:report().identity))
        XCTAssertNil(try store.latestComparison(sourceFingerprint:String(repeating:"a",count:64)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
}
