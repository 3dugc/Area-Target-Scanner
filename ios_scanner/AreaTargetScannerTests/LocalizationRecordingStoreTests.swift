import XCTest
import simd
import Darwin
@testable import AreaTargetScanner

final class LocalizationRecordingStoreTests: XCTestCase {
    private let source = String(repeating: "a", count: 64)
    private let context = LocalizationRecordingContext(deviceModel: "iPhone15,2", systemVersion: "18.0", appVersion: "1.0", appBuild: "7", previewDroppedFrames: 3)

    func testSaveRestoresExactNormalizedFramesAndImmutableContext() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let originals = try (0..<3).map { try frame($0) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let recording = try store.save(frames: originals, videoURL: video, sourceFingerprint: source, context: context)
        XCTAssertEqual(recording.frameCount, 3)
        XCTAssertEqual(recording.duration, 3)
        XCTAssertEqual(recording.context, context)
        XCTAssertEqual(recording.inputDigest, try LocalizationRecordingStore.inputDigest(frames: originals))
        let reopened = LocalizationRecordingStore(rootDirectory: root)
        XCTAssertEqual(try reopened.list(sourceFingerprint: source), [recording])
        let loaded = try reopened.load(recording)
        XCTAssertEqual(loaded.count, originals.count)
        for (original, restored) in zip(originals, loaded) { assertExact(original, restored) }
        XCTAssertEqual(try Data(contentsOf: reopened.videoURL(for: recording)), try Data(contentsOf: video))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path), "Saving copies; caller owns its temporary preview")
        XCTAssertEqual(try reopened.videoURL(for: recording).deletingLastPathComponent().lastPathComponent, recording.id.uuidString.lowercased())
    }

    func testCanonicalInputDigestIncludesPixelsAndEveryNumericBitPattern() throws {
        let original = try frame(0)
        let positive = try LocalizationQueryFrame(sequence: 0, timestamp: 0, pixels: original.pixels, width: 2, height: 2,
            intrinsics: original.intrinsics, worldFromCamera: matrix_identity_float4x4)
        var negativePose = matrix_identity_float4x4; negativePose.columns.3.y = -Float.zero
        let negative = try LocalizationQueryFrame(sequence: 0, timestamp: -Double.zero, pixels: original.pixels, width: 2, height: 2,
            intrinsics: original.intrinsics, worldFromCamera: negativePose)
        XCTAssertNotEqual(try LocalizationRecordingStore.inputDigest(frames: [positive]), try LocalizationRecordingStore.inputDigest(frames: [negative]))
        let changed = try LocalizationQueryFrame(sequence: 0, timestamp: 0, pixels: Data([9, 2, 3, 4]), width: 2, height: 2,
            intrinsics: original.intrinsics, worldFromCamera: matrix_identity_float4x4)
        XCTAssertNotEqual(try LocalizationRecordingStore.inputDigest(frames: [positive]), try LocalizationRecordingStore.inputDigest(frames: [changed]))
        XCTAssertEqual(try LocalizationRecordingStore.inputDigest(frames: [positive]), try LocalizationRecordingStore.inputDigest(frames: [positive]))
    }

    func testSavedRecordingIsExcludedFromDeviceBackup() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let recording = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let package = try store.videoURL(for: recording).deletingLastPathComponent()
        #if os(macOS)
        // macOS's /tmp is already outside backup policy and its URL getter may
        // report false even while the explicit backup-exclusion xattr is present.
        XCTAssertGreaterThan(getxattr(package.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0), 0)
        #else
        XCTAssertEqual(try package.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #endif
    }

    func testPixelVideoAndManifestTamperingInvalidateRecording() throws {
        for filename in ["frames.bin", "preview.mp4", "manifest.json"] {
            let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
            let store = LocalizationRecordingStore(rootDirectory: root)
            let recording = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
            let folder = try store.videoURL(for: recording).deletingLastPathComponent()
            let damaged = folder.appendingPathComponent(filename)
            var bytes = try Data(contentsOf: damaged); bytes[bytes.count / 2] ^= 1
            try bytes.write(to: damaged)
            XCTAssertThrowsError(try store.load(recording), filename)
            XCTAssertThrowsError(try store.videoURL(for: recording), filename)
            XCTAssertTrue(try store.list(sourceFingerprint: source).isEmpty, filename)
        }
    }

    func testSourceIsolationAndMissingStoreDoNotCreateDirectories() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        XCTAssertTrue(try store.list(sourceFingerprint: source).isEmpty)
        XCTAssertTrue(try store.invalidRecordingIDs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        _ = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        XCTAssertTrue(try store.list(sourceFingerprint: String(repeating: "b", count: 64)).isEmpty)
        XCTAssertThrowsError(try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: "../../escape", context: context))
        XCTAssertThrowsError(try store.list(sourceFingerprint: "unknown"))
    }

    func testRejectsInvalidFrameSequenceIntervalCountAndContextWithoutConsumingVideo() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let invalids = [[], [try frame(0), try frame(0)], [try frame(0), try frame(1, time: 1.49)], try (0..<33).map { try frame($0) }]
        for frames in invalids {
            XCTAssertThrowsError(try store.save(frames: frames, videoURL: video, sourceFingerprint: source, context: context))
        }
        let badContext = LocalizationRecordingContext(deviceModel: "device", systemVersion: "os", appVersion: "app", appBuild: "build", previewDroppedFrames: -1)
        XCTAssertThrowsError(try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: badContext))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRootMissingParentAndPackageSymlinksAreRejected() throws {
        let root = temporary(), outside = temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        XCTAssertThrowsError(try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: root)
        let nestedStore = LocalizationRecordingStore(rootDirectory: root.appendingPathComponent("missing/cache"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("missing"), withDestinationURL: outside)
        XCTAssertThrowsError(try nestedStore.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context))
        try FileManager.default.removeItem(at: root.appendingPathComponent("missing"))
        let recording = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let package = try store.videoURL(for: recording).deletingLastPathComponent()
        let pixels = package.appendingPathComponent("frames.bin")
        let copy = outside.appendingPathComponent("pixels.bin"); try FileManager.default.moveItem(at: pixels, to: copy)
        try FileManager.default.createSymbolicLink(at: pixels, withDestinationURL: copy)
        XCTAssertThrowsError(try store.load(recording))
        XCTAssertTrue(try store.list(sourceFingerprint: source).isEmpty)
    }

    func testOversizeVideoAndTotalBudgetFailWithoutDeletingExistingRecordings() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let first = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let oversized = temporary(); defer { try? FileManager.default.removeItem(at: oversized) }
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let huge = try FileHandle(forWritingTo: oversized); try huge.truncate(atOffset: UInt64(LocalizationRecordingStore.maximumVideoBytes + 1)); try huge.close()
        XCTAssertThrowsError(try store.save(frames: [try frame(0)], videoURL: oversized, sourceFingerprint: source, context: context))
        let filler = root.appendingPathComponent("budget.bin")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler); try handle.truncate(atOffset: UInt64(LocalizationRecordingStore.maximumTotalBytes)); try handle.close()
        XCTAssertThrowsError(try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context))
        XCTAssertEqual(try store.load(first).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.path))
    }

    func testDeleteRemovesOnlyRequestedUUIDAndRejectsForgedMetadata() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let first = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let second = try store.save(frames: [try frame(1)], videoURL: video, sourceFingerprint: source, context: context)
        let forged = LocalizationRecording(id: first.id, date: first.date, sourceFingerprint: String(repeating: "b", count: 64), inputDigest: first.inputDigest, frameCount: first.frameCount, duration: first.duration, context: first.context)
        XCTAssertThrowsError(try store.load(forged))
        XCTAssertThrowsError(try store.delete(forged))
        try store.delete(first)
        XCTAssertThrowsError(try store.load(first))
        XCTAssertEqual(try store.list(sourceFingerprint: source), [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testAbandonedPendingPackageIsReclaimedBeforeQuotaCheckWithoutDeletingHealthyRecordings() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let healthy = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let pending = root.appendingPathComponent(".pending-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let incomplete = pending.appendingPathComponent("frames.bin")
        FileManager.default.createFile(atPath: incomplete.path, contents: nil)
        let sparse = try FileHandle(forWritingTo: incomplete)
        try sparse.truncate(atOffset: UInt64(LocalizationRecordingStore.maximumTotalBytes)); try sparse.close()
        try Data([1]).write(to: pending.appendingPathComponent("preview.mp4"))
        let tombstone = root.appendingPathComponent(".deleted-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: tombstone, withIntermediateDirectories: false)
        try Data([1]).write(to: tombstone.appendingPathComponent("frames.bin"))
        let unrelated = root.appendingPathComponent(".pending-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let second = try LocalizationRecordingStore(rootDirectory: root).save(frames: [try frame(1)], videoURL: video, sourceFingerprint: source, context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(Set(try store.listAll().map(\.id)), Set([healthy.id, second.id]))
        XCTAssertEqual(try store.load(healthy).count, 1)
    }

    func testDirectoryLockProtectsAnotherActiveSaveFromStagingCleanup() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(owner, 0); defer { Darwin.close(owner) }
        XCTAssertEqual(flock(owner, LOCK_EX), 0); defer { flock(owner, LOCK_UN) }
        let pending = root.appendingPathComponent(".pending-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        try Data([1]).write(to: pending.appendingPathComponent("frames.bin"))
        let finished = DispatchSemaphore(value: 0)
        let other = LocalizationRecordingStore(rootDirectory: root)
        DispatchQueue.global(qos: .userInitiated).async {
            do { let recordings = try other.listAll(); XCTAssertTrue(recordings.isEmpty) } catch { XCTFail("Second store failed: \(error)") }
            finished.signal()
        }
        let status = finished.wait(timeout: .now() + 0.1)
        XCTAssertEqual(status, .timedOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "An active writer owns its staging until the directory lock is released")
        XCTAssertEqual(flock(owner, LOCK_UN), 0)
        if status == .timedOut { XCTAssertEqual(finished.wait(timeout: .now() + 3), .success) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testInvalidPackagesAreDiscoverableAndExplicitDeletionRechecksHealthyPackage() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = try temporaryVideo(); defer { try? FileManager.default.removeItem(at: video) }
        let store = LocalizationRecordingStore(rootDirectory: root)
        let healthy = try store.save(frames: [try frame(0)], videoURL: video, sourceFingerprint: source, context: context)
        let bad = try store.save(frames: [try frame(1)], videoURL: video, sourceFingerprint: source, context: context)
        let badVideo = try store.videoURL(for: bad)
        let originalVideo = try Data(contentsOf: badVideo)
        try Data("corrupt".utf8).write(to: badVideo)
        XCTAssertEqual(try store.invalidRecordingIDs(), [bad.id])
        XCTAssertEqual(try store.listAll(), [healthy])
        XCTAssertThrowsError(try store.deleteInvalid(id: healthy.id))
        try originalVideo.write(to: badVideo)
        XCTAssertThrowsError(try store.deleteInvalid(id: bad.id), "A previously invalid list does not authorize deleting a restored recording")
        XCTAssertEqual(try store.load(bad).count, 1)
        try Data("corrupt".utf8).write(to: badVideo)
        try store.deleteInvalid(id: bad.id)
        XCTAssertTrue(try store.invalidRecordingIDs().isEmpty)
        XCTAssertEqual(try store.load(healthy).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: badVideo.deletingLastPathComponent().path))
    }

    func testInvalidDeletionAndStagingCleanupUnlinkSymlinksWithoutFollowingTheirTargets() throws {
        let root = temporary(), outside = temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.bin"); try Data([7]).write(to: sentinel)
        let pendingLink = root.appendingPathComponent(".pending-" + UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: pendingLink, withDestinationURL: outside)
        let id = UUID(), package = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let nested = package.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("external"), withDestinationURL: outside)
        let linkID = UUID(), link = root.appendingPathComponent(linkID.uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = LocalizationRecordingStore(rootDirectory: root)
        XCTAssertEqual(Set(try store.invalidRecordingIDs()), Set([id, linkID]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingLink.path))
        try store.deleteInvalid(id: id); try store.deleteInvalid(id: linkID)
        XCTAssertTrue(try store.invalidRecordingIDs().isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([7]))
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("localization-recording-" + UUID().uuidString) }
    private func temporaryVideo() throws -> URL { let url = temporary().appendingPathExtension("mp4"); try Data([0, 0, 0, 24, 102, 116, 121, 112]).write(to: url); return url }
    private func frame(_ sequence: Int, time: Double? = nil) throws -> LocalizationQueryFrame {
        var pose = matrix_identity_float4x4; pose.columns.3.x = Float(sequence) * 0.2
        if sequence == 0 { pose.columns.3.y = -Float.zero }
        return try LocalizationQueryFrame(sequence: sequence, timestamp: time ?? Double(sequence) * 1.5,
            pixels: Data([UInt8(sequence), 2, 3, 4]), width: 2, height: 2, intrinsics: SIMD4(2.125, 2.25, 1, 1), worldFromCamera: pose)
    }
    private func assertExact(_ lhs: LocalizationQueryFrame, _ rhs: LocalizationQueryFrame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.sequence, rhs.sequence, file: file, line: line)
        XCTAssertEqual(lhs.timestamp.bitPattern, rhs.timestamp.bitPattern, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, file: file, line: line); XCTAssertEqual(lhs.height, rhs.height, file: file, line: line)
        XCTAssertEqual(lhs.pixels, rhs.pixels, file: file, line: line)
        for column in 0..<4 {
            XCTAssertEqual(lhs.intrinsics[column].bitPattern, rhs.intrinsics[column].bitPattern, file: file, line: line)
            for row in 0..<4 { XCTAssertEqual(lhs.worldFromCamera[column][row].bitPattern, rhs.worldFromCamera[column][row].bitPattern, file: file, line: line) }
        }
    }
}
