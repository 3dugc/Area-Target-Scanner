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
        let original = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let originalImage = try Data(contentsOf: root.appendingPathComponent("images/frame.jpg"))
        let originalFingerprint = try ScanSourceFingerprint.compute(directory: root)
        for requirements in try [preparationRequirements(), v2Requirements()] {
            let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            let before = Set(names.filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
            let cancellation = ArchiveCancellationFlag()
            XCTAssertThrowsError(try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: requirements, progress: { text in
                if text.hasPrefix("正在准备上传关键帧") { cancellation.cancel() }
            }, isCancelled: { cancellation.value })) { error in
                XCTAssertEqual(error as? AreaTargetScanArchive.ArchiveError, .cancelled, requirements.policy)
            }
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
            XCTAssertEqual(before, after, requirements.policy)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), original, requirements.policy)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/frame.jpg")), originalImage, requirements.policy)
            XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root), originalFingerprint, requirements.policy)
        }
    }

    private func preparationRequirements(policy: String = "mobile-scan-preparation-v1") throws -> AreaTargetProcessingRequirements {
        try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: Data("{\"schemaVersion\":1,\"policy\":\"\(policy)\",\"policyVersion\":1,\"profiles\":{\"fast\":{\"maxFrames\":80,\"maximumLongEdge\":1600,\"maximumTotalPixels\":200000000},\"quality\":{\"maxFrames\":80,\"maximumLongEdge\":1600,\"maximumTotalPixels\":200000000}},\"safety\":{\"maximumRequestBytes\":536870912,\"maximumExpandedBytes\":524288000,\"maximumArchiveEntries\":10000,\"maximumSourceFrameCount\":10000,\"maximumImagePixels\":32000000,\"maximumImageDimension\":8192,\"maximumMetadataBytes\":8388608}}".utf8))
    }

    func testV2UploadsEverySourceFrameWithoutApplyingWorkingFrameOrPixelCap() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 1921, height: 1441)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let template = try XCTUnwrap((manifest["frames"] as? [[String: Any]])?.first)
        let frames: [[String: Any]] = try (0..<120).map { index in
            var frame = template
            let path = "images/source_\(index).jpg"
            try FileManager.default.copyItem(at: root.appendingPathComponent("images/frame.jpg"), to: root.appendingPathComponent(path))
            frame["imageFile"] = path
            frame["index"] = index + 1000; frame["timestamp"] = Double(index + 1)
            frame["image"] = ["width": 1921, "height": 1441]
            frame["intrinsics"] = ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720]
            return frame
        }
        manifest["frames"] = frames
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let source = try ScanSourceFingerprint.compute(directory: root)
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: v2Requirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        var bytes = Data(); _ = try archive.extract(try XCTUnwrap(archive["manifest.json"])) { bytes.append($0) }
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let prepared = try XCTUnwrap(stored["frames"] as? [[String: Any]])
        XCTAssertEqual(stored["schemaVersion"] as? Int, 1)
        XCTAssertEqual(prepared.count, 120)
        XCTAssertEqual(prepared.compactMap { $0["index"] as? Int }, Array(1000..<1120))
        XCTAssertEqual(Set(prepared.compactMap { $0["imageFile"] as? String }).count, 120)
        for frame in prepared {
            XCTAssertNotEqual(frame["imageFile"] as? String, "images/frame.jpg")
            XCTAssertEqual(frame["image"] as? [String: Int], ["width": 1600, "height": 1200])
            let k = try XCTUnwrap(frame["intrinsics"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(k["fx"]), 1500.0 * 1600 / 1921, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(k["fy"]), 1510.0 * 1200 / 1441, accuracy: 0.0001)
        }
        let record = try XCTUnwrap(stored["clientPreparation"] as? [String: Any])
        XCTAssertEqual(record["receivedFrameCount"] as? Int, 120)
        XCTAssertEqual(record["selectedFrameCount"] as? Int, 120)
        XCTAssertEqual(record["selectedIndices"] as? [Int], Array(0..<120))
        XCTAssertEqual(record["capacityTier"] as? Int, 100)
        XCTAssertEqual(record["selectionVersion"] as? String, "upload-all-v2")
        XCTAssertEqual(record["processedPixelCount"] as? Int, 120 * 1600 * 1200)
        let selection: [String: Any] = ["capacityTier": 100, "policy": "mobile-scan-preparation-v2", "selectedIndices": Array(0..<120), "selectionVersion": "upload-all-v2"]
        let expected = SHA256.hash(data: try JSONSerialization.data(withJSONObject: selection, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(record["selectionDigest"] as? String, expected)
        XCTAssertNotNil(try AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root), source)
    }

    func testV2CameraDerivativePreservesSharedMaterialImageBytesAndDoesNotUpscale() throws {
        try Data("mtllib model.mtl\nv 0 0 0\nf 1 2 3\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try Data("newmtl scan\nmap_Kd images/frame.jpg\n".utf8).write(to: root.appendingPathComponent("model.mtl"))
        let original = try Data(contentsOf: root.appendingPathComponent("images/frame.jpg"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: false, profile: "fast", requirements: v2Requirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        func data(_ path: String) throws -> Data { var result = Data(); _ = try archive.extract(try XCTUnwrap(archive[path])) { result.append($0) }; return result }
        XCTAssertEqual(try data("images/frame.jpg"), original)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data("manifest.json")) as? [String: Any])
        let frame = try XCTUnwrap((stored["frames"] as? [[String: Any]])?.first)
        let path = try XCTUnwrap(frame["imageFile"] as? String)
        XCTAssertNotEqual(path, "images/frame.jpg")
        XCTAssertEqual(try data(path), original)
        XCTAssertEqual(frame["image"] as? [String: Int], ["width": 100, "height": 100])
    }

    func testV2ByteBudgetShrinksAllFramesTogetherAndRejectsAtMinimumEdge() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 1920, height: 1440)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        var frame = try XCTUnwrap((manifest["frames"] as? [[String: Any]])?.first)
        frame["image"] = ["width": 1920, "height": 1440]
        frame["intrinsics"] = ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720]
        manifest["frames"] = [frame]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let source = try ScanSourceFingerprint.compute(directory: root)
        let requirements = try v2Requirements()
        let bounded = AreaTargetScanArchive(maximumExpandedBytes: 20_000)
        let output = try bounded.archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: requirements, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let preparation = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(preparation.selectedFrameCount, 1)
        XCTAssertLessThan(preparation.maximumOutputLongEdge, 1600)
        XCTAssertGreaterThanOrEqual(preparation.maximumOutputLongEdge, 1024)
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        let before = Set(names.filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
        XCTAssertThrowsError(try AreaTargetScanArchive(maximumExpandedBytes: 4096).archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: requirements, progress: { _ in }, isCancelled: { false })) { error in
            XCTAssertEqual(error as? AreaTargetScanArchive.ArchiveError, .uploadBudgetExceeded)
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("area-target-prepared-") || $0.hasPrefix("area-target-scan-") })
        XCTAssertEqual(before, after)
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: root), source)
    }

    func testV2ByteBudgetPinsMinimumLongEdgeWithoutFloatingPointUndershoot() throws {
        try writeImage(to: root.appendingPathComponent("images/frame.jpg"), width: 1122, height: 1122)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        var frame = try XCTUnwrap((manifest["frames"] as? [[String: Any]])?.first)
        frame["image"] = ["width": 1122, "height": 1122]
        frame["intrinsics"] = ["fx": 1000, "fy": 1000, "cx": 561, "cy": 561]
        manifest["frames"] = [frame]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let output = try AreaTargetScanArchive(maximumExpandedBytes: 19_000).archive(scanDirectory: root, uvUnwrap: true, profile: "fast", requirements: v2Requirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let preparation = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(preparation.maximumOutputLongEdge, 1024)
        XCTAssertEqual(preparation.processedPixelCount, 1024 * 1024)
    }

    func testPreparationReaderRejectsMissingOrForgedV2ProvenanceAndKeepsV1Endpoints() throws {
        let digest = try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1])
        let preparation = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 2, selectedFrameCount: 2, selectedIndices: [0, 1],
            processedPixelCount: 20_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "a", count: 64),
            receivedFrameCount: 2, capacityTier: 100, selectionVersion: "upload-all-v2", selectionDigest: digest)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preparation)) as? [String: Any])
        func read(_ record: [String: Any]) throws -> AreaTargetClientPreparation? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create)
            let bytes = try JSONSerialization.data(withJSONObject: ["clientPreparation": record])
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(bytes.count)) { position, count in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + count))
            }
            return try AreaTargetScanArchive.clientPreparation(in: url)
        }
        XCTAssertEqual(try read(valid), preparation)
        for key in ["receivedFrameCount", "capacityTier", "selectionVersion", "selectionDigest"] {
            var invalid = valid; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try read(invalid), key)
        }
        let mutations: [String: Any] = ["receivedFrameCount": 1, "capacityTier": 999, "selectionVersion": "server-dedup-v2",
            "selectionDigest": String(repeating: "b", count: 64), "originalFrameCount": 3, "selectedIndices": [0],
            "processedPixelCount": 2 * 1600 * 1600 + 1]
        for (key, replacement) in mutations {
            var invalid = valid; invalid[key] = replacement
            XCTAssertThrowsError(try read(invalid), key)
        }
        var legacy = valid
        legacy["policy"] = "mobile-scan-preparation-v1"; legacy["policyVersion"] = 1; legacy["originalFrameCount"] = 3
        legacy["selectedIndices"] = [0, 2]
        XCTAssertNotNil(try read(legacy))
        for indices in [[1, 2], [0, 1]] { legacy["selectedIndices"] = indices; XCTAssertThrowsError(try read(legacy)) }
    }

    func testCriticalProtectionSelectsEightRiskFramesPreservesBytesAndCalibration() throws {
        let before = try writeCriticalFrames(count: 10)
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast",
            requirements: protectedRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        func bytes(_ path: String) throws -> Data {
            var value = Data(); _ = try archive.extract(try XCTUnwrap(archive[path])) { value.append($0) }; return value
        }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes("manifest.json")) as? [String: Any])
        let frames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        let record = try XCTUnwrap(document["clientPreparation"] as? [String: Any])
        let protection = try XCTUnwrap(record["criticalFrameProtection"] as? [String: Any])
        XCTAssertEqual(Set(protection.keys), ["version", "riskVersion", "protectedIndices", "candidateFrameCount"])
        XCTAssertEqual(protection["protectedIndices"] as? [Int], Array(0..<8))
        XCTAssertEqual(protection["candidateFrameCount"] as? Int, 10)
        XCTAssertEqual(frames.count, 10)
        for (index, frame) in frames.enumerated() {
            let protected = index < 8
            XCTAssertEqual(frame["image"] as? [String: Int], ["width": protected ? 1920 : 1600, "height": protected ? 1440 : 1200])
            let k = try XCTUnwrap(frame["intrinsics"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(k["fx"]), protected ? 1500 : 1250, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(k["fy"]), protected ? 1510 : 1510 * 1200 / 1440, accuracy: 0.0001)
            XCTAssertEqual(frame["index"] as? Int, index)
            XCTAssertEqual(frame["timestamp"] as? Double, Double(index + 1))
            XCTAssertEqual(frame["imageOrientation"] as? String, "landscapeRight")
            if protected { XCTAssertEqual(try bytes(try XCTUnwrap(frame["imageFile"] as? String)), before[index]) }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/critical_\(index).jpg")), before[index])
        }
        XCTAssertEqual(try AreaTargetScanArchive.clientPreparation(in: output)?.maximumOutputLongEdge, 1920)
    }

    func testCriticalProtectionCannotShrinkProtectedFramesToFitByteBudget() throws {
        let before = try writeCriticalFrames(count: 1)
        XCTAssertThrowsError(try AreaTargetScanArchive(maximumExpandedBytes: 20_000).archive(scanDirectory: root,
            uvUnwrap: true, profile: "fast", requirements: protectedRequirements(), progress: { _ in }, isCancelled: { false })) {
            XCTAssertEqual($0 as? AreaTargetScanArchive.ArchiveError, .uploadBudgetExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/critical_0.jpg")), before[0])
    }

    func testCriticalRiskBoundariesRejectionPriorityAndSharpnessOrdering() throws {
        let capability = try XCTUnwrap(protectedRequirements().criticalFrameProtection)
        func quality(_ sharpness: Double, _ contrast: Double = 40, rejection: ScanFrameQuality.Rejection? = nil) -> ScanFrameQuality {
            .init(rejection: rejection, sharpness: sharpness, contrast: contrast, mean: 128, sampleCount: 10)
        }
        let values = [quality(16, 21), quality(17, 20), quality(16.1, 20.1), quality(90, rejection: .exposure),
            quality(9), quality(80, rejection: .blur), quality(9), quality(10), quality(11), quality(12), quality(13), quality(14)]
        let record = try AreaTargetScanArchive.criticalProtection(qualities: values, capability: capability)
        XCTAssertEqual(record.candidateFrameCount, 11, "Both threshold equalities count as risk")
        XCTAssertEqual(record.protectedIndices, [3, 4, 5, 6, 7, 8, 9, 10], "Rejected frames outrank accepted candidates even with larger sharpness")
        let ties = try AreaTargetScanArchive.criticalProtection(qualities: Array(repeating: quality(9), count: 10), capability: capability)
        XCTAssertEqual(ties.protectedIndices, Array(0..<8))
        let empty = try AreaTargetScanArchive.criticalProtection(qualities: [quality(17, 21)], capability: capability)
        XCTAssertEqual(empty.protectedIndices, []); XCTAssertEqual(empty.candidateFrameCount, 0)
        XCTAssertThrowsError(try AreaTargetScanArchive.criticalProtection(qualities: [quality(0, rejection: .unreadable)], capability: capability))
    }

    func testCriticalProtectionKeepsNonOrdinalIDsAndScalesUnevenDimensionsPerAxis() throws {
        _ = try writeCriticalFrames(count: 2)
        try writeImage(to: root.appendingPathComponent("images/critical_0.jpg"), width: 1921, height: 1441)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        var source = try XCTUnwrap(document["frames"] as? [[String: Any]])
        source[0]["index"] = 1000; source[1]["index"] = 5000
        source[0]["image"] = ["width": 1921, "height": 1441]
        source[0]["imageOrientation"] = "landscapeLeft"
        source[0]["transform"] = [1,0,0,0,0,1,0,0,0,0,1,0,0.25,0.5,0.75,1]
        document["frames"] = source
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
        let output = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast",
            requirements: protectedRequirements(), progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        var bytes = Data(); _ = try archive.extract(try XCTUnwrap(archive["manifest.json"])) { bytes.append($0) }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let frames = try XCTUnwrap(manifest["frames"] as? [[String: Any]])
        let record = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(record.criticalFrameProtection?.protectedIndices, [0, 1])
        XCTAssertEqual(frames.compactMap { $0["index"] as? Int }, [1000, 5000])
        XCTAssertEqual(frames[0]["image"] as? [String: Int], ["width": 1920, "height": 1440])
        let k = try XCTUnwrap(frames[0]["intrinsics"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(k["fx"]), 1500.0 * 1920 / 1921, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(k["fy"]), 1510.0 * 1440 / 1441, accuracy: 0.000001)
        XCTAssertEqual(frames[0]["imageOrientation"] as? String, "landscapeLeft")
        XCTAssertEqual(frames[0]["transform"] as? [Double], source[0]["transform"] as? [Double])
        XCTAssertEqual(frames[0]["timestamp"] as? Double, source[0]["timestamp"] as? Double)
    }

    func testCriticalByteRetryShrinksOnlyOrdinaryFramesAndFreezesProtection() throws {
        let before = try writeCriticalFrames(count: 9)
        let requirements = try protectedRequirements()
        let full = try AreaTargetScanArchive().archive(scanDirectory: root, uvUnwrap: true, profile: "fast",
            requirements: requirements, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: full) }
        let original = try Archive(url: full, accessMode: .read)
        var manifestData = Data(); _ = try original.extract(try XCTUnwrap(original["manifest.json"])) { manifestData.append($0) }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let frames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        let ordinaryPath = try XCTUnwrap(frames[8]["imageFile"] as? String)
        let fullBytes = original.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        let budget = fullBytes - Int64(try XCTUnwrap(original[ordinaryPath]).uncompressedSize) + 18_000
        XCTAssertLessThan(budget, fullBytes)
        let output = try AreaTargetScanArchive(maximumExpandedBytes: budget).archive(scanDirectory: root, uvUnwrap: true,
            profile: "fast", requirements: requirements, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let archive = try Archive(url: output, accessMode: .read)
        var bytes = Data(); _ = try archive.extract(try XCTUnwrap(archive["manifest.json"])) { bytes.append($0) }
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let prepared = try XCTUnwrap(stored["frames"] as? [[String: Any]])
        let record = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        XCTAssertEqual(record.criticalFrameProtection?.protectedIndices, Array(0..<8))
        XCTAssertEqual(record.criticalFrameProtection?.candidateFrameCount, 9)
        XCTAssertEqual(record.maximumOutputLongEdge, 1920)
        for (index, frame) in prepared.enumerated() {
            let size = try XCTUnwrap(frame["image"] as? [String: Int])
            if index < 8 {
                XCTAssertEqual(size, ["width": 1920, "height": 1440])
                var encoded = Data(); _ = try archive.extract(try XCTUnwrap(archive[try XCTUnwrap(frame["imageFile"] as? String)])) { encoded.append($0) }
                XCTAssertEqual(encoded, before[index])
            } else {
                XCTAssertLessThan(try XCTUnwrap(size["width"]), 1600)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(size["width"]), 1024)
            }
        }
    }

    func testV2RetryRejectsSourceMutationBetweenBudgetAttempts() throws {
        _ = try writeCriticalFrames(count: 1)
        let source = root.appendingPathComponent("images/critical_0.jpg")
        let requirements = try v2Requirements()
        XCTAssertThrowsError(try AreaTargetScanArchive(maximumExpandedBytes: 20_000).archive(scanDirectory: root,
            uvUnwrap: true, profile: "fast", requirements: requirements, progress: { detail in
                if detail.contains("超过字节预算") {
                    let handle = try! FileHandle(forWritingTo: source)
                    try! handle.seekToEnd(); try! handle.write(contentsOf: Data([0])); try! handle.close()
                }
            }, isCancelled: { false })) {
            XCTAssertEqual($0 as? AreaTargetScanArchive.ArchiveError, .invalidScan("扫描源文件已改变，请重新创建上传任务"))
        }
    }

    func testRealCriticalProtectionArchiveWhenFixtureIsExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["AREA_TARGET_CRITICAL_FIXTURE_DIR"] else {
            throw XCTSkip("Real capture diagnostic requires an explicit local fixture")
        }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        let before = try ScanSourceFingerprint.compute(directory: source)
        var baselineRequirements = try protectedRequirements(profile: "quality")
        baselineRequirements.criticalFrameProtection = nil
        let baseline = try AreaTargetScanArchive().archive(scanDirectory: source, uvUnwrap: true, profile: "quality",
            requirements: baselineRequirements, progress: { _ in }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: baseline) }
        let output = try AreaTargetScanArchive().archive(scanDirectory: source, uvUnwrap: true, profile: "quality",
            requirements: protectedRequirements(profile: "quality"), progress: { print("CRITICAL_REAL_PROGRESS: " + $0) }, isCancelled: { false })
        defer { try? FileManager.default.removeItem(at: output) }
        let record = try XCTUnwrap(AreaTargetScanArchive.clientPreparation(in: output))
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let protection = try XCTUnwrap(object["criticalFrameProtection"] as? [String: Any])
        XCTAssertEqual(protection["protectedIndices"] as? [Int], Array(47...54))
        XCTAssertEqual(record.selectedFrameCount, 94)
        XCTAssertEqual(try ScanSourceFingerprint.compute(directory: source), before)
        print("CRITICAL_REAL_ARCHIVE: " + output.path)
        print("CRITICAL_REAL_PREPARATION: " + String(decoding: data, as: UTF8.self))
        print("CRITICAL_REAL_SOURCE_FINGERPRINT: " + before)
        if let destination = ProcessInfo.processInfo.environment["AREA_TARGET_CRITICAL_OUTPUT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (file, name) in [(baseline, "ios-baseline94.zip"), (output, "ios-protected94.zip")] {
                let saved = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.removeItem(at: saved) }
                try FileManager.default.copyItem(at: file, to: saved)
            }
            try data.write(to: directory.appendingPathComponent("ios-critical94-preparation.json"))
            try JSONEncoder().encode(AreaTargetScanArchive.clientPreparation(in: baseline)).write(to: directory.appendingPathComponent("ios-baseline94-preparation.json"))
            try Data(before.utf8).write(to: directory.appendingPathComponent("ios-source-fingerprint.txt"))
        }
    }

    func testCriticalPreparationReaderValidatesStrictMetadataAndSourceBudget() throws {
        let prep = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 101, selectedFrameCount: 101, selectedIndices: Array(0..<101),
            processedPixelCount: 210_000_000, resizedFrameCount: 93, maximumOutputLongEdge: 1920, scaleDigest: String(repeating: "a", count: 64),
            receivedFrameCount: 101, capacityTier: 100, selectionVersion: "upload-all-v2",
            selectionDigest: try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: Array(0..<101)),
            criticalFrameProtection: .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: Array(47...54), candidateFrameCount: 21))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prep)) as? [String: Any])
        func read(_ record: [String: Any]) throws -> AreaTargetClientPreparation? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create)
            let bytes = try JSONSerialization.data(withJSONObject: ["clientPreparation": record])
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(bytes.count)) { position, count in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + count))
            }
            return try AreaTargetScanArchive.clientPreparation(in: url)
        }
        XCTAssertEqual(try read(valid), prep, "Upload metadata uses the source budget, not the server's 200M working budget")
        let cap = try XCTUnwrap(valid["criticalFrameProtection"] as? [String: Any])
        for key in cap.keys {
            var altered = cap; altered.removeValue(forKey: key)
            var invalid = valid; invalid["criticalFrameProtection"] = altered
            XCTAssertThrowsError(try read(invalid), key)
        }
        let mutations: [String: Any] = ["version": "future", "riskVersion": "future", "unexpected": 1,
            "protectedIndices": [47, 47], "candidateFrameCount": 7]
        for (key, replacement) in mutations {
            var altered = cap; altered[key] = replacement
            var invalid = valid; invalid["criticalFrameProtection"] = altered
            XCTAssertThrowsError(try read(invalid), key)
        }
        for indices in [[-1], [101], [54, 47], Array(0..<9)] {
            var altered = cap; altered["protectedIndices"] = indices
            var invalid = valid; invalid["criticalFrameProtection"] = altered
            XCTAssertThrowsError(try read(invalid))
        }
        for count in [true, 21.5, -1, 102] as [Any] {
            var altered = cap; altered["candidateFrameCount"] = count
            var invalid = valid; invalid["criticalFrameProtection"] = altered
            XCTAssertThrowsError(try read(invalid))
        }
        for bad in [NSNull(), true] as [Any] {
            var invalid = valid; invalid["criticalFrameProtection"] = bad
            XCTAssertThrowsError(try read(invalid))
        }
        for (key, value) in ["processedPixelCount": 2_000_000_001, "maximumOutputLongEdge": 1921] {
            var invalid = valid; invalid[key] = value; XCTAssertThrowsError(try read(invalid))
        }
        var noCap = valid; noCap.removeValue(forKey: "criticalFrameProtection")
        XCTAssertThrowsError(try read(noCap), "1920 requires the explicit protection record")
    }

    func testCriticalPreparationReaderRejectsIntegralFloatAndBooleanTokens() throws {
        let prep = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 1, selectedFrameCount: 1, selectedIndices: [0],
            processedPixelCount: 10_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "a", count: 64),
            receivedFrameCount: 1, capacityTier: 100, selectionVersion: "upload-all-v2",
            selectionDigest: try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0]),
            criticalFrameProtection: .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [0], candidateFrameCount: 1))
        let original = String(decoding: try JSONEncoder().encode(prep), as: UTF8.self)
        for (old, new) in [("\"candidateFrameCount\":1", "\"candidateFrameCount\":1.0"),
            ("\"candidateFrameCount\":1", "\"candidateFrameCount\":1e0"),
            ("\"candidateFrameCount\":1", "\"candidateFrameCount\":true"),
            ("\"protectedIndices\":[0]", "\"protectedIndices\":[0.0]"),
            ("\"protectedIndices\":[0]", "\"protectedIndices\":[false]")] {
            let record = original.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(record, original)
            let bytes = Data(("{\"clientPreparation\":" + record + "}").utf8)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(bytes.count)) { position, count in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + count))
            }
            XCTAssertThrowsError(try AreaTargetScanArchive.clientPreparation(in: url), new)
        }
    }

    private func writeCriticalFrames(count: Int) throws -> [Data] {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let template = try XCTUnwrap((document["frames"] as? [[String: Any]])?.first)
        var frames: [[String: Any]] = [], images: [Data] = []
        for index in 0..<count {
            let path = "images/critical_\(index).jpg"
            try writeImage(to: root.appendingPathComponent(path), width: 1920, height: 1440)
            images.append(try Data(contentsOf: root.appendingPathComponent(path)))
            var frame = template; frame["index"] = index; frame["timestamp"] = Double(index + 1); frame["imageFile"] = path
            frame["image"] = ["width": 1920, "height": 1440]
            frame["intrinsics"] = ["fx": 1500, "fy": 1510, "cx": 960, "cy": 720]
            frames.append(frame)
        }
        document["frames"] = frames
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("manifest.json"))
        return images
    }

    private func protectedRequirements(profile: String = "fast") throws -> AreaTargetProcessingRequirements {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v2Requirements())) as? [String: Any])
        if profile == "quality" { value["profiles"] = ["quality": value["profiles"].flatMap { ($0 as? [String: Any])?["fast"] }!] }
        value["criticalFrameProtection"] = ["version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
            "maximumProtectedFrames": 8, "maximumProtectedLongEdge": 1920, "sharpnessThreshold": 16, "contrastThreshold": 20]
        return try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func v2Requirements(tier: Int = 100) throws -> AreaTargetProcessingRequirements {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preparationRequirements())) as? [String: Any])
        value["policy"] = "mobile-scan-preparation-v2"; value["policyVersion"] = 2; value["capacityTier"] = tier
        value["profiles"] = ["fast": ["maxFrames": tier, "maximumLongEdge": 1600, "minimumLongEdge": 1024,
            "maximumTotalPixels": tier == 100 ? 200_000_000 : 600_000_000]]
        return try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: value))
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
