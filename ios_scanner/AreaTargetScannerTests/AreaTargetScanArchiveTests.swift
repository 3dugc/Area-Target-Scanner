import XCTest
import CryptoKit
import ZIPFoundation
import CoreGraphics
import ImageIO
@testable import AreaTargetScanner

final class AreaTargetScanArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetScanArchiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"))
        try writeManifest()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testBuildsFreshWhitelistArchiveForUntexturedUVScan() throws {
        for name in ["model.usdz", "model.glb", "pointcloud.ply", "old-share.zip", "notes.txt"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        let archive = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: archive) }
        let paths = Set(try Archive(url: archive, accessMode: .read).map(\.path))
        XCTAssertEqual(paths, ["manifest.json", "model.obj", "images/frame.jpg"])
        XCTAssertFalse(archive.path.hasPrefix(root.path + "/"))
        let next = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: next) }
        XCTAssertNotEqual(archive, next)
    }

    func testRejectsUntexturedScanWhenUVIsDisabled() {
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: false, progress: { _ in }, isCancelled: { false }))
    }

    func testTexturedOBJIncludesOnlyItsReferencedMTLAndTexture() throws {
        try Data("mtllib model.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try Data("newmtl scan\nmap_Kd texture.jpg\n".utf8).write(to: root.appendingPathComponent("model.mtl"))
        try writeImage(to: root.appendingPathComponent("texture.jpg"))
        try Data([1]).write(to: root.appendingPathComponent("unused.png"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: false, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(Set(try Archive(url: output, accessMode: .read).map(\.path)), ["manifest.json", "model.obj", "model.mtl", "texture.jpg", "images/frame.jpg"])
    }

    func testRejectsFramePathEscapeMissingFrameAndSymlink() throws {
        for image in ["../frame.jpg", "/outside.jpg", "images/missing.jpg", "images/../frame.jpg"] {
            try writeManifest(image: image)
            XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
        }
        try writeManifest()
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/frame.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("images/frame.jpg"), withDestinationURL: root.appendingPathComponent("model.obj"))
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
    }

    func testRejectsInvalidNativeContractAndIncompleteMetadata() throws {
        for mutation in [["schemaVersion": 2], ["schemaVersion": true], ["units": "feet"], ["frames": []]] as [[String: Any]] {
            try writeManifest(mutation: mutation)
            XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
        }
    }

    func testRejectsBooleanFrameIndex() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        var frames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        frames[0]["index"] = true
        document["frames"] = frames
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
    }

    func testSparseOversizedModelIsRejectedBeforeReading() throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("model.obj"))
        try handle.truncate(atOffset: UInt64(AreaTargetFileSafety.maximumExpandedBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
    }

    func testLargeNativeScanArchivesEveryOriginalFrameWithoutChangingPixelsMetadataOrSource() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 1920, height: 1440)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let template = try XCTUnwrap((original["frames"] as? [[String: Any]])?.first)
        var frames: [[String: Any]] = []
        var sourcePaths = ["manifest.json", "model.obj", "images/frame.jpg"]
        for index in 0..<120 {
            let name = "images/frame_\(index).jpg"
            try FileManager.default.copyItem(at: root.appendingPathComponent("images/frame.jpg"), to: root.appendingPathComponent(name))
            var frame = template
            frame["index"] = index
            frame["timestamp"] = Double(index + 1)
            frame["imageFile"] = name
            frame["image"] = ["width": 1920, "height": 1440]
            frame["intrinsics"] = ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720]
            frames.append(frame)
            sourcePaths.append(name)
        }
        func sourceDigests() throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: sourcePaths.map { path in
                (path, try AreaTargetFileSafety.digest(root.appendingPathComponent(path),
                    maximum: AreaTargetFileSafety.maximumExpandedBytes).sha256)
            })
        }
        for frameCount in [73, 120] {
            var document = original
            document["frames"] = Array(frames.prefix(frameCount))
            try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
            let before = try sourceDigests()
            let originalFingerprint = try ScanSourceFingerprint.compute(directory: root)
            let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true,
                progress: { _ in }, isCancelled: { false })
            defer { try? FileManager.default.removeItem(at: output) }
            let archive = try Archive(url: output, accessMode: .read)
            let expectedPaths = Set(["manifest.json", "model.obj"] + (0..<frameCount).map { "images/frame_\($0).jpg" })
            XCTAssertEqual(Set(archive.map(\.path)), expectedPaths, "All referenced original frames must be uploaded")
            for path in expectedPaths {
                let entry = try XCTUnwrap(archive[path])
                var digest = SHA256()
                var bytes = Data()
                _ = try archive.extract(entry) { chunk in
                    digest.update(data: chunk)
                    if path.hasPrefix("images/") || path == "manifest.json" { bytes.append(chunk) }
                }
                XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(), before[path],
                    "The archive must preserve the exact original bytes: \(path)")
                if path.hasPrefix("images/") {
                    let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
                    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
                    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1920)
                    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1440)
                } else if path == "manifest.json" {
                    let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    let storedFrames = try XCTUnwrap(stored["frames"] as? [[String: Any]])
                    XCTAssertEqual(storedFrames.count, frameCount)
                    for (index, frame) in storedFrames.enumerated() {
                        XCTAssertEqual(frame["index"] as? Int, index)
                        XCTAssertEqual(frame["image"] as? [String: Int], ["width": 1920, "height": 1440])
                        XCTAssertEqual(frame["intrinsics"] as? [String: Int], ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720])
                        XCTAssertEqual(frame["transform"] as? [Double], template["transform"] as? [Double])
                    }
                }
            }
            XCTAssertEqual(try sourceDigests(), before, "Preparing an upload must never alter the original scan")
            XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root), originalFingerprint)
        }
    }

    func testCancellationNeverReturnsArchive() {
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { true })) { error in
            XCTAssertEqual(error as? AreaTargetScanArchive.ArchiveError, .cancelled)
        }
    }

    func testRejectsActualImageDimensionsMismatchAndUndecodableImage() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 101)
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("images/frame.jpg"))
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false }))
    }

    func testRejectsTexturePathEscape() throws {
        try Data("mtllib model.mtl\nv 0 0 0\nf 1 2 3\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try Data("newmtl scan\nmap_Kd ../outside.jpg\n".utf8).write(to: root.appendingPathComponent("model.mtl"))
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: false, progress: { _ in }, isCancelled: { false }))
    }

    func testCancellationDuringWritingCleansOwnedTemporaryArchive() throws {
        let flag = ArchiveCancellationFlag()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("area-target-scan-") })
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { text in if text.hasPrefix("正在打包") { flag.cancel() } }, isCancelled: { flag.value })) { error in
            XCTAssertEqual(error as? AreaTargetScanArchive.ArchiveError, .cancelled)
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("area-target-scan-") })
        XCTAssertEqual(before, after)
    }

    func testLegacyPosesAndIntrinsicsArePreserved() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["frames": manifest["frames"]!]).write(to: root.appendingPathComponent("poses.json"))
        try JSONSerialization.data(withJSONObject: ["fx": 100, "fy": 100, "cx": 50, "cy": 50, "width": 100, "height": 100]).write(to: root.appendingPathComponent("intrinsics.json"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(Set(try Archive(url: output, accessMode: .read).map(\.path)), ["poses.json", "intrinsics.json", "model.obj", "images/frame.jpg"])
    }

    func testRequirementsPrepareUniformWholeScanAndScaledCalibrationWithoutChangingRawFiles() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 1920, height: 1440)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let template = try XCTUnwrap((document["frames"] as? [[String: Any]])?.first)
        var frames: [[String: Any]] = []
        for index in 0..<120 {
            let name = "images/frame_\(index).jpg"
            try FileManager.default.copyItem(at: root.appendingPathComponent("images/frame.jpg"), to: root.appendingPathComponent(name))
            var frame = template
            frame["index"] = index; frame["timestamp"] = Double(index + 1); frame["imageFile"] = name
            frame["image"] = ["width": 1920, "height": 1440]
            frame["intrinsics"] = ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720]
            frames.append(frame)
        }
        document["frames"] = frames
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["frames": frames]).write(to: root.appendingPathComponent("poses.json"))
        try JSONSerialization.data(withJSONObject: ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720, "width": 1920, "height": 1440]).write(to: root.appendingPathComponent("intrinsics.json"))
        let paths = ["manifest.json", "poses.json", "intrinsics.json", "model.obj", "images/frame.jpg"] + frames.compactMap { $0["imageFile"] as? String }
        let before = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try AreaTargetFileSafety.digest(root.appendingPathComponent($0), maximum: AreaTargetFileSafety.maximumExpandedBytes).sha256) })
        let originalFingerprint = try ScanSourceFingerprint.compute(directory: root)
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "quality", requirements: preparationRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        func bytes(_ path: String) throws -> Data {
            var data = Data(); _ = try archive.extract(try XCTUnwrap(archive[path])) { data.append($0) }; return data
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes("manifest.json")) as? [String: Any])
        let prepared = try XCTUnwrap(manifest["frames"] as? [[String: Any]])
        XCTAssertEqual(prepared.count, 80)
        let indices = (0..<80).map { ($0 * 119 + 39) / 79 }
        XCTAssertEqual(prepared.compactMap { $0["index"] as? Int }, indices)
        let metadata = try XCTUnwrap(manifest["clientPreparation"] as? [String: Any])
        let policy = try JSONDecoder().decode(AreaTargetClientPreparation.self, from: JSONSerialization.data(withJSONObject: metadata))
        XCTAssertEqual(policy.originalFrameCount, 120); XCTAssertEqual(policy.selectedFrameCount, 80)
        XCTAssertEqual(policy.selectedIndices, indices); XCTAssertEqual(policy.preparedBy, "client")
        XCTAssertEqual(policy.processedPixelCount, 80 * 1600 * 1200)
        XCTAssertEqual(policy.resizedFrameCount, 80); XCTAssertEqual(policy.maximumOutputLongEdge, 1600)
        let scales = indices.map { ["index": $0, "width": 1920, "height": 1440, "outputWidth": 1600, "outputHeight": 1200] }
        XCTAssertEqual(policy.scaleDigest, SHA256.hash(data: try JSONSerialization.data(withJSONObject: scales, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined())
        for (offset, frame) in prepared.enumerated() {
            XCTAssertEqual(frame["image"] as? [String: Int], ["width": 1600, "height": 1200])
            let k = try XCTUnwrap(frame["intrinsics"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(k["fx"]), 1500.0 * 1600 / 1920, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(k["fy"]), 1510.0 * 1200 / 1440, accuracy: 0.0001)
            XCTAssertEqual(k["cx"], 800); XCTAssertEqual(k["cy"], 600)
            XCTAssertEqual(frame["transform"] as? [Double], template["transform"] as? [Double])
            XCTAssertEqual(frame["imageOrientation"] as? String, "landscapeRight")
            let image = try XCTUnwrap(CGImageSourceCreateWithData(try bytes("images/frame_\(indices[offset]).jpg") as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1600)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 1200)
        }
        let poses = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes("poses.json")) as? [String: Any])
        XCTAssertEqual((poses["frames"] as? [[String: Any]])?.count, 80)
        let shared = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes("intrinsics.json")) as? [String: Double])
        XCTAssertEqual(shared["width"], 1600); XCTAssertEqual(shared["height"], 1200)
        XCTAssertEqual(shared["cx"], 800); XCTAssertEqual(shared["cy"], 600)
        XCTAssertEqual(Set(archive.map(\.path)), Set(["manifest.json", "poses.json", "intrinsics.json", "model.obj"] + indices.map { "images/frame_\($0).jpg" }))
        for path in paths { XCTAssertEqual(try AreaTargetFileSafety.digest(root.appendingPathComponent(path), maximum: AreaTargetFileSafety.maximumExpandedBytes).sha256, before[path]) }
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root), originalFingerprint)
    }

    func testUnsupportedRequirementsFallbackToOriginalArchive() throws {
        let requirements = try preparationRequirements(policy: "future-policy")
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: requirements, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        var data = Data(); _ = try archive.extract(try XCTUnwrap(archive["manifest.json"])) { data.append($0) }
        XCTAssertEqual(data, try Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    func testSquareFramesUseAggregatePixelBudgetAndActualDimensionScale() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 2000, height: 2000)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let template = try XCTUnwrap((document["frames"] as? [[String: Any]])?.first)
        var frames: [[String: Any]] = []
        for index in 0..<80 {
            let path = "images/frame_\(index).jpg"
            try FileManager.default.copyItem(at: root.appendingPathComponent("images/frame.jpg"), to: root.appendingPathComponent(path))
            var frame = template
            frame["index"] = index; frame["timestamp"] = Double(index + 1); frame["imageFile"] = path
            frame["image"] = ["width": 2000, "height": 2000]
            frame["intrinsics"] = ["fx": 1000, "fy": 1100, "cx": 1000, "cy": 1000]
            frames.append(frame)
        }
        document["frames"] = frames
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: preparationRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let preparation = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(preparation.processedPixelCount, 80 * 1581 * 1581)
        XCTAssertLessThanOrEqual(preparation.processedPixelCount, 200_000_000)
        XCTAssertEqual(preparation.maximumOutputLongEdge, 1581)
        let archive = try Archive(url: output, accessMode: .read)
        var bytes = Data(); _ = try archive.extract(try XCTUnwrap(archive["manifest.json"])) { bytes.append($0) }
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for frame in try XCTUnwrap(stored["frames"] as? [[String: Any]]) {
            XCTAssertEqual(frame["image"] as? [String: Int], ["width": 1581, "height": 1581])
            let k = try XCTUnwrap(frame["intrinsics"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(k["fx"]), 1000.0 * 1581 / 2000, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(k["fy"]), 1100.0 * 1581 / 2000, accuracy: 0.0001)
        }
    }

    func testPreparedLegacyScanKeepsUnscaledJPEGBytesAndSyncsNativeAndLegacyMetadata() throws {
        let original = try Data(contentsOf: root.appendingPathComponent("images/frame.jpg"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let frame = try XCTUnwrap((value["frames"] as? [[String: Any]])?.first)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["frames": [frame]]).write(to: root.appendingPathComponent("poses.json"))
        try JSONSerialization.data(withJSONObject: ["fx": 100, "fy": 100, "cx": 50, "cy": 50, "width": 100, "height": 100]).write(to: root.appendingPathComponent("intrinsics.json"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: preparationRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        var bytes = Data(); _ = try archive.extract(try XCTUnwrap(archive["images/frame.jpg"])) { bytes.append($0) }
        XCTAssertEqual(bytes, original, "Unscaled images must be copied, not decoded/re-encoded")
        XCTAssertEqual(try AreaTargetScanArchive.clientPreparation(in: output)?.resizedFrameCount, 0)
        XCTAssertNotNil(archive["manifest.json"]); XCTAssertNotNil(archive["poses.json"]); XCTAssertNotNil(archive["intrinsics.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }

    func testLegacyPreparationPreservesKnownLandscapeLeftInManifestAndPoses() throws {
        let imageURL = root.appendingPathComponent("images/frame.jpg")
        let originalImage = try Data(contentsOf: imageURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        var frame = try XCTUnwrap((document["frames"] as? [[String: Any]])?.first)
        frame["imageOrientation"] = "landscapeLeft"
        let originalTransform = try XCTUnwrap(frame["transform"] as? [Int])
        let posesURL = root.appendingPathComponent("poses.json")
        let originalPoses = try JSONSerialization.data(withJSONObject: ["frames": [frame]])
        try originalPoses.write(to: posesURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["fx": 100, "fy": 100, "cx": 50, "cy": 50, "width": 100, "height": 100]).write(to: root.appendingPathComponent("intrinsics.json"))

        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: preparationRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        for path in ["manifest.json", "poses.json"] {
            var bytes = Data()
            _ = try archive.extract(try XCTUnwrap(archive[path])) { bytes.append($0) }
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let preparedFrame = try XCTUnwrap((stored["frames"] as? [[String: Any]])?.first)
            XCTAssertEqual(preparedFrame["imageOrientation"] as? String, "landscapeLeft", path)
            XCTAssertEqual(preparedFrame["transform"] as? [Int], originalTransform, path)
        }
        var preparedImage = Data()
        _ = try archive.extract(try XCTUnwrap(archive["images/frame.jpg"])) { preparedImage.append($0) }
        XCTAssertEqual(preparedImage, originalImage)
        XCTAssertEqual(try Data(contentsOf: posesURL), originalPoses)
        XCTAssertEqual(try Data(contentsOf: imageURL), originalImage)
    }

    func testCancellationDuringClientPreparationCleansOnlyOwnedTemporaryFiles() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        let before = Set(names.filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
        let original = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let cancellation = ArchiveCancellationFlag()
        XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: preparationRequirements(), progress: { text in
            if text.hasPrefix("正在准备上传关键帧") { cancellation.cancel() }
        }, isCancelled: { cancellation.value }))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/frame.jpg").path))
    }

    private func preparationRequirements(policy: String = "mobile-scan-preparation-v1") throws -> AreaTargetProcessingRequirements {
        try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: Data("{\"schemaVersion\":1,\"policy\":\"\(policy)\",\"policyVersion\":1,\"profiles\":{\"fast\":{\"maxFrames\":80,\"maximumLongEdge\":1600,\"maximumTotalPixels\":200000000},\"quality\":{\"maxFrames\":80,\"maximumLongEdge\":1600,\"maximumTotalPixels\":200000000}},\"safety\":{\"maximumRequestBytes\":536870912,\"maximumExpandedBytes\":524288000,\"maximumArchiveEntries\":10000,\"maximumSourceFrameCount\":10000,\"maximumImagePixels\":32000000,\"maximumImageDimension\":8192,\"maximumMetadataBytes\":8388608}}".utf8))
    }

    private func writeManifest(image: String = "images/frame.jpg", mutation: [String: Any] = [:]) throws {
        var value: [String: Any] = ["schemaVersion": 1, "coordinateSystem": "arkit-world", "matrixLayout": "arkit-column-major", "units": "meters", "frames": [["index": 0, "timestamp": 1.0, "imageFile": image, "transform": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], "imageOrientation": "landscapeRight", "image": ["width": 100, "height": 100], "intrinsics": ["fx": 100, "fy": 100, "cx": 50, "cy": 50]]]]
        mutation.forEach { value[$0.key] = $0.value }
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("manifest.json"))
    }

    private func writeImage(to url: URL, width: Int = 100, height: Int = 100) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class ArchiveCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
