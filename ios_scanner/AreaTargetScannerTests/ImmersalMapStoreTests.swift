import XCTest
import CryptoKit
@testable import AreaTargetScanner

final class ImmersalMapStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersalMapStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testMissingMapReturnsNilWithoutCreatingCacheDirectories() throws {
        let store = ImmersalMapStore(rootURL: root)
        XCTAssertNil(try store.mapURL(userID: 7, mapID: 123))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSavedMapRestoresVerifiedBytesAndAccountMapIdentity() throws {
        let store = ImmersalMapStore(rootURL: root)
        let bytes = Data([1, 2, 3, 4, 5])
        let url = try store.save(data: bytes, userID: 7, mapID: 123)
        XCTAssertEqual(url.pathExtension, "bytes")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let restored = ImmersalMapStore(rootURL: root)
        XCTAssertEqual(try restored.mapURL(userID: 7, mapID: 123), url)
        XCTAssertNil(try restored.mapURL(userID: 8, mapID: 123))
        XCTAssertNil(try restored.mapURL(userID: 7, mapID: 124))
        let descriptor = try Data(contentsOf: descriptorURL(userID: 7, mapID: 123))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptor) as? [String: Any])
        XCTAssertEqual(json["userID"] as? Int, 7)
        XCTAssertEqual(json["mapID"] as? Int, 123)
        XCTAssertEqual(json["byteCount"] as? Int, bytes.count)
        XCTAssertEqual(json["sha256"] as? String, hash(bytes))
        XCTAssertNil(json["token"])
        XCTAssertNil(json["password"])
    }

    func testSameMapIDInDifferentAccountsHasIndependentFiles() throws {
        let store = ImmersalMapStore(rootURL: root)
        let first = try store.save(data: Data([1]), userID: 7, mapID: 123)
        let second = try store.save(data: Data([2]), userID: 8, mapID: 123)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.mapURL(userID: 7, mapID: 123))), Data([1]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.mapURL(userID: 8, mapID: 123))), Data([2]))
    }

    func testCorruptMapBytesAndMissingMapFileAreReported() throws {
        let store = ImmersalMapStore(rootURL: root)
        let url = try store.save(data: Data([1, 2, 3]), userID: 7, mapID: 123)
        try Data([3, 2, 1]).write(to: url)
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123))
    }

    func testDescriptorFromAnotherAccountOrMapIsRejected() throws {
        let store = ImmersalMapStore(rootURL: root)
        try store.save(data: Data([1]), userID: 7, mapID: 123)
        try store.save(data: Data([1]), userID: 8, mapID: 123)
        try store.save(data: Data([1]), userID: 7, mapID: 124)
        let source = try Data(contentsOf: descriptorURL(userID: 7, mapID: 123))
        try source.write(to: descriptorURL(userID: 8, mapID: 123))
        try source.write(to: descriptorURL(userID: 7, mapID: 124))
        XCTAssertThrowsError(try store.mapURL(userID: 8, mapID: 123))
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 124))
    }

    func testMalformedHashSizeAndDescriptorAreRejected() throws {
        let store = ImmersalMapStore(rootURL: root)
        try store.save(data: Data([1]), userID: 7, mapID: 123)
        let descriptorFile = descriptorURL(userID: 7, mapID: 123)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: descriptorFile)) as? [String: Any])
        for (key, value) in [("sha256", "../../outside" as Any), ("byteCount", 2 as Any), ("schemaVersion", 2 as Any)] {
            var json = original; json[key] = value
            try JSONSerialization.data(withJSONObject: json).write(to: descriptorFile)
            XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123), key)
        }
        try Data("broken cache descriptor".utf8).write(to: descriptorFile)
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123))
    }

    func testInvalidIDsEmptyDataAndOversizedDataDoNotAlterGoodCache() throws {
        let store = ImmersalMapStore(rootURL: root, maximumMapBytes: 3)
        let original = Data([1, 2, 3])
        let url = try store.save(data: original, userID: 7, mapID: 123)
        for data in [Data(), Data([1, 2, 3, 4])] {
            XCTAssertThrowsError(try store.save(data: data, userID: 7, mapID: 123))
        }
        for (userID, mapID) in [(-1, 123), (7, 0), (7, -1)] {
            XCTAssertThrowsError(try store.save(data: Data([1]), userID: userID, mapID: mapID))
            XCTAssertThrowsError(try store.mapURL(userID: userID, mapID: mapID))
        }
        XCTAssertEqual(try store.mapURL(userID: 7, mapID: 123), url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testDescriptorPublicationFailurePreservesExistingMapAndDescriptor() throws {
        let store = ImmersalMapStore(rootURL: root)
        let original = Data([1, 2, 3])
        let url = try store.save(data: original, userID: 7, mapID: 123)
        let previousDescriptor = try Data(contentsOf: descriptorURL(userID: 7, mapID: 123))
        let failing = ImmersalMapStore(rootURL: root, publishDescriptor: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try failing.save(data: Data([9, 8, 7]), userID: 7, mapID: 123))
        XCTAssertEqual(try store.mapURL(userID: 7, mapID: 123), url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: descriptorURL(userID: 7, mapID: 123)), previousDescriptor)
    }

    func testSuccessfulReplacementPublishesNewVerifiedMapAndPreservesPreviouslyReturnedFile() throws {
        let store = ImmersalMapStore(rootURL: root)
        let previous = try store.save(data: Data([1]), userID: 7, mapID: 123)
        let updated = try store.save(data: Data([2]), userID: 7, mapID: 123)
        XCTAssertNotEqual(previous, updated)
        XCTAssertEqual(try store.mapURL(userID: 7, mapID: 123), updated)
        XCTAssertEqual(try Data(contentsOf: previous), Data([1]))
        XCTAssertEqual(try Data(contentsOf: updated), Data([2]))
    }

    func testAccountDirectorySymlinkCannotReadOrOverwriteAnotherAccountsCache() throws {
        let store = ImmersalMapStore(rootURL: root)
        let other = try store.save(data: Data([2]), userID: 8, mapID: 123)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("7"),
                                                  withDestinationURL: root.appendingPathComponent("8"))
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123))
        XCTAssertThrowsError(try store.save(data: Data([1]), userID: 7, mapID: 123))
        XCTAssertEqual(try store.mapURL(userID: 8, mapID: 123), other)
        XCTAssertEqual(try Data(contentsOf: other), Data([2]))
    }

    func testDownloadedBytesCanRepairACorruptCache() throws {
        let store = ImmersalMapStore(rootURL: root)
        let bytes = Data([1, 2, 3])
        let url = try store.save(data: bytes, userID: 7, mapID: 123)
        try Data([9]).write(to: url)
        XCTAssertThrowsError(try store.mapURL(userID: 7, mapID: 123))
        try store.save(data: bytes, userID: 7, mapID: 123)
        XCTAssertEqual(try store.mapURL(userID: 7, mapID: 123), url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func descriptorURL(userID: Int, mapID: Int) -> URL {
        root.appendingPathComponent(String(userID)).appendingPathComponent(String(mapID)).appendingPathComponent("current.json")
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
