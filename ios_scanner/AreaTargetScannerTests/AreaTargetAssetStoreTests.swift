import XCTest
import ZIPFoundation
import CryptoKit
@testable import AreaTargetScanner

final class AreaTargetAssetStoreTests: XCTestCase {
    private var root: URL!
    private let jobID = "5c372062-9130-40ed-9efe-5ef336c7e332"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetAssetStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testValidBundlePersistsAndRestoresVerifiedCanonicalAsset() throws {
        let zip = try fixture()
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let saved = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        XCTAssertEqual(saved.jobID, jobID)
        XCTAssertEqual(saved.modelURL.lastPathComponent, "optimized.glb")
        XCTAssertEqual(saved.featuresURL.lastPathComponent, "features.db")
        XCTAssertEqual(saved.manifestURL.lastPathComponent, "manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertEqual(try store.asset(jobID: jobID), saved)
        XCTAssertEqual(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets")).asset(jobID: jobID), saved)
    }

    func testSavedAssetURLsAreCanonicalAcrossParentPathAliases() throws {
        let zip = try fixture()
        let parent = root.appendingPathComponent("canonical-parent", isDirectory: true)
        let alias = root.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Construct before the alias exists so initialization cannot normalize it.
        // The asset cache itself is a real directory beneath this parent alias.
        let store = AreaTargetAssetStore(rootDirectory: alias.appendingPathComponent("assets", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)

        let saved = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        let canonicalStore = AreaTargetAssetStore(rootDirectory: parent.appendingPathComponent("assets", isDirectory: true))
        XCTAssertEqual(try store.asset(jobID: jobID), saved)
        XCTAssertEqual(try canonicalStore.asset(jobID: jobID), saved)
        for url in [saved.bundleURL, saved.directoryURL, saved.modelURL, saved.featuresURL, saved.manifestURL] {
            XCTAssertEqual(url, url.resolvingSymlinksInPath())
        }
    }

    func testSymlinkedAssetRootIsRejectedBeforeReturningCanonicalURLs() throws {
        let zip = try fixture()
        let target = root.appendingPathComponent("real-assets", isDirectory: true)
        let alias = root.appendingPathComponent("assets-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let store = AreaTargetAssetStore(rootDirectory: alias)

        XCTAssertThrowsError(try store.save(downloadURL: zip, jobID: jobID, result: result(zip)))
        XCTAssertThrowsError(try store.asset(jobID: jobID))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testDigestAndByteLengthMismatchCannotPublish() throws {
        let zip = try fixture()
        let good = try result(zip)
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        for bad in [AreaTargetResult(format: good.format, filename: good.filename, sizeBytes: good.sizeBytes + 1, sha256: good.sha256, url: good.url, expiresAt: good.expiresAt), AreaTargetResult(format: good.format, filename: good.filename, sizeBytes: good.sizeBytes, sha256: String(repeating: "0", count: 64), url: good.url, expiresAt: good.expiresAt)] {
            XCTAssertThrowsError(try store.save(downloadURL: zip, jobID: jobID, result: bad))
            XCTAssertNil(try store.asset(jobID: jobID))
        }
    }

    func testZipTraversalSymlinkAndDuplicateNamesAreRejected() throws {
        for (path, type) in [("../outside", Entry.EntryType.file), ("/outside", .file), ("link", .symlink), ("optimized.glb", .file)] {
            let zip = try fixture(extra: (path, type, Data("outside".utf8)))
            XCTAssertThrowsError(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent(UUID().uuidString)).save(downloadURL: zip, jobID: jobID, result: result(zip)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    func testManifestCannotReferenceOutsideOrUnexpectedFiles() throws {
        for mutation in [["version": "1.0"], ["meshFile": "../optimized.glb"], ["featureDbFile": "other.db"], ["format": "obj"]] {
            let zip = try fixture(manifestMutation: mutation)
            XCTAssertThrowsError(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent(UUID().uuidString)).save(downloadURL: zip, jobID: jobID, result: result(zip)))
        }
    }

    func testExpandedEntryOverLimitIsRejectedBeforeExtraction() throws {
        let zip = try fixture()
        var data = try Data(contentsOf: zip)
        let central = try XCTUnwrap(data.range(of: Data([0x50,0x4b,0x01,0x02])))
        let size = UInt32(AreaTargetFileSafety.maximumExpandedBytes + 1)
        for byte in 0..<4 { data[central.lowerBound + 24 + byte] = UInt8(truncatingIfNeeded: size >> (byte * 8)) }
        try data.write(to: zip)
        XCTAssertThrowsError(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets")).save(downloadURL: zip, jobID: jobID, result: result(zip)))
    }

    func testCorruptZIPMemberCRCIsRejected() throws {
        let zip = try fixture()
        var data = try Data(contentsOf: zip)
        let marker = try XCTUnwrap(data.range(of: Data("SQLite format 3\0fixture".utf8)))
        data[marker.upperBound - 1] ^= 1
        try data.write(to: zip)
        XCTAssertThrowsError(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets")).save(downloadURL: zip, jobID: jobID, result: result(zip)))
    }

    func testMalformedGLBAndMissingFeatureDatabaseAreRejected() throws {
        for zip in [try fixture(glb: Data("not glb".utf8)), try fixture(omitFeatures: true)] {
            XCTAssertThrowsError(try AreaTargetAssetStore(rootDirectory: root.appendingPathComponent(UUID().uuidString)).save(downloadURL: zip, jobID: jobID, result: result(zip)))
        }
    }

    func testFailedReplacementPreservesPreviouslySavedAsset() throws {
        let good = try fixture()
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let saved = try store.save(downloadURL: good, jobID: jobID, result: result(good))
        let bad = try fixture(manifestMutation: ["meshFile": "../escape"])
        XCTAssertThrowsError(try store.save(downloadURL: bad, jobID: jobID, result: result(bad)))
        XCTAssertEqual(try store.asset(jobID: jobID), saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
    }

    func testInvalidJobAndSymlinkedCacheDirectoryAreRejected() throws {
        let zip = try fixture()
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent(jobID), withDestinationURL: root)
        let store = AreaTargetAssetStore(rootDirectory: assets)
        XCTAssertThrowsError(try store.save(downloadURL: zip, jobID: jobID, result: result(zip)))
        XCTAssertThrowsError(try store.asset(jobID: jobID))
        XCTAssertThrowsError(try store.asset(jobID: "../outside"))
    }

    func testCorruptSavedBundleIsDetectedOnRestore() throws {
        let zip = try fixture()
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let saved = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        try Data([1]).write(to: saved.bundleURL)
        XCTAssertThrowsError(try store.asset(jobID: jobID))
    }

    func testCorruptExtractedFileWithUnchangedHeaderIsDetectedOnRestore() throws {
        let zip = try fixture()
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let saved = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        let file = try FileHandle(forWritingTo: saved.featuresURL)
        try file.seekToEnd()
        try file.write(contentsOf: Data("tampered".utf8))
        try file.close()
        XCTAssertThrowsError(try store.asset(jobID: jobID))
    }

    func testSuccessfulRetryRetainsPreviousImmutableGeneration() throws {
        let zip = try fixture()
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let first = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        let second = try store.save(downloadURL: zip, jobID: jobID, result: result(zip))
        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.bundleURL.path))
        XCTAssertEqual(try store.asset(jobID: jobID), second)
    }

    private func fixture(extra: (String, Entry.EntryType, Data)? = nil, manifestMutation: [String: String] = [:], glb: Data? = nil, omitFeatures: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        var manifest: [String: Any] = ["version": "2.0", "meshFile": "optimized.glb", "featureDbFile": "features.db", "format": "glb", "bounds": ["min": [0,0,0], "max": [1,1,1]], "keyframeCount": 1]
        manifestMutation.forEach { manifest[$0.key] = $0.value }
        let model = glb ?? Data([0x67,0x6c,0x54,0x46,2,0,0,0,20,0,0,0,0,0,0,0,0x4a,0x53,0x4f,0x4e])
        var entries = [("manifest.json", Entry.EntryType.file, try JSONSerialization.data(withJSONObject: manifest)), ("optimized.glb", .file, model)]
        if !omitFeatures { entries.append(("features.db", .file, Data("SQLite format 3\0fixture".utf8))) }
        if let extra { entries.append(extra) }
        for (name, type, data) in entries {
            try archive.addEntry(with: name, type: type, uncompressedSize: Int64(data.count), provider: { position, count in data.subdata(in: Int(position)..<min(data.count, Int(position) + count)) })
        }
        return url
    }

    private func result(_ url: URL) throws -> AreaTargetResult {
        let data = try Data(contentsOf: url)
        return AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(3600))
    }
}
