import XCTest
@testable import AreaTargetScanner

final class ScanSourceFingerprintTests: XCTestCase {
    func testSameRawCaptureIgnoresDirectoryNameAndExtraMetadata() throws {
        let first = try fixture(); let second = first.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try FileManager.default.copyItem(at: first, to: second)
        try Data("different display name".utf8).write(to: second.appendingPathComponent("scene-name.txt"))
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: first), try ScanSourceFingerprint.compute(directory: second))
    }
    func testImageAndModelChangesChangeIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try ScanSourceFingerprint.compute(directory: root)
        try Data([9,8,7]).write(to: root.appendingPathComponent("images/frame.jpg"))
        let imageChanged = try ScanSourceFingerprint.compute(directory: root)
        XCTAssertNotEqual(original, imageChanged)
        try Data("v 1 0 0\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        XCTAssertNotEqual(imageChanged, try ScanSourceFingerprint.compute(directory: root))
    }
    func testUnsafeMetadataPathAndSymlinkAreRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try metadata(path: "images/../../outside.jpg").write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root))
        try metadata(path: "images/frame.jpg").write(to: root.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/frame.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("images/frame.jpg"), withDestinationURL: root.appendingPathComponent("model.obj"))
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root))
    }
    func testCancellationAndMalformedIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root, isCancelled: { true }))
        XCTAssertFalse(ScanSourceFingerprint.valid(nil))
        XCTAssertFalse(ScanSourceFingerprint.valid(String(repeating: "g", count: 64)))
        XCTAssertTrue(ScanSourceFingerprint.valid(try ScanSourceFingerprint.compute(directory: root)))
    }

    func testOriginalCaptureOverUploadBudgetRetainsFullSourceIdentity() throws {
        let root = try sparseFixture(frameCount: 2, imageBytes: 260 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try ScanSourceFingerprint.compute(directory: root)
        XCTAssertTrue(ScanSourceFingerprint.valid(original))
        // A change near EOF must still enter the raw identity, beyond the ZIP budget.
        let image = root.appendingPathComponent("images/frame_1.jpg")
        let handle = try FileHandle(forWritingTo: image)
        try handle.seek(toOffset: UInt64(260 * 1024 * 1024 - 1))
        try handle.write(contentsOf: Data([2]))
        try handle.close()
        XCTAssertNotEqual(original, try ScanSourceFingerprint.compute(directory: root))
    }

    func testVersionOneIdentityRemainsCompatibleWithExistingCaptures() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root),
            "4a6d8c07766ca336119d6e0846d6119190e0bd68fa91f855a1a758bbc4fcfc39")
    }

    func testIndividualSourceFileRemainsBoundedTo500MiB() throws {
        let root = try sparseFixture(frameCount: 1, imageBytes: 500 * 1024 * 1024 + 1)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root, isCancelled: {
            checks += 1; return false
        })) { error in
            guard case ScanSourceFingerprint.Failure.invalid = error else { return XCTFail("Expected per-file limit, got \(error)") }
        }
        XCTAssertEqual(checks, 1, "Reject oversized files before reading their contents")
    }

    func testOriginalAggregateRemainsBoundedToEightGiB() throws {
        // Sparse files reserve almost no disk space, but the real stream hashes bytes.
        let root = try sparseFixture(frameCount: 33, imageBytes: 260 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root)) { error in
            guard case ScanSourceFingerprint.Failure.invalid = error else { return XCTFail("Expected source-work budget, got \(error)") }
        }
    }

    func testCancellationDuringLargeOriginalStreamStopsEarly() throws {
        let root = try sparseFixture(frameCount: 2, imageBytes: 260 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        XCTAssertThrowsError(try ScanSourceFingerprint.compute(directory: root, isCancelled: {
            checks += 1; return checks == 6
        })) { error in
            guard case ScanSourceFingerprint.Failure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertEqual(checks, 6, "Cancellation must stop while streaming the first image")
    }

    private func sparseFixture(frameCount: Int, imageBytes: Int) throws -> URL {
        let root = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata(path: "images/frame.jpg")) as? [String: Any])
        let template = try XCTUnwrap((object["frames"] as? [[String: Any]])?.first)
        var frames: [[String: Any]] = []
        for index in 0..<frameCount {
            let path = "images/frame_\(index).jpg"
            let url = root.appendingPathComponent(path)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(imageBytes))
            try handle.seek(toOffset: UInt64(imageBytes - 1))
            try handle.write(contentsOf: Data([1]))
            try handle.close()
            var frame = template
            frame["index"] = index; frame["timestamp"] = index + 1; frame["imageFile"] = path
            frames.append(frame)
        }
        object["frames"] = frames
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        return root
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: root.appendingPathComponent("images/frame.jpg"))
        try Data("v 0 0 0\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try metadata(path: "images/frame.jpg").write(to: root.appendingPathComponent("manifest.json"))
        return root
    }
    private func metadata(path: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["frames": [
            ["index": 0, "timestamp": 1, "imageFile": path,
             "transform": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
             "image": ["width": 4, "height": 3],
             "intrinsics": ["fx": 2, "fy": 2, "cx": 2, "cy": 1.5]]
        ]], options: [.sortedKeys])
    }
}
