import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import AreaTargetScanner

final class ImmersalScanExporterTests: XCTestCase {
    private var root: URL!
    private var scan: URL!
    private let width = 48
    private let height = 32
    private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        scan = root.appendingPathComponent("scan_fixture")
        try FileManager.default.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDirectUploadMatchesArchiveWithoutCreatingZIP() throws {
        try writeScan(frames: [frame(index: 7, run: 123), frame(index: 42, run: 123)])
        let exporter = ImmersalScanExporter()
        let prepared = try exporter.prepareUpload(scanDirectory: scan, isCancelled: { false })
        XCTAssertEqual(prepared.frameCount, 2)
        let direct = try exporter.uploadFrame(at: 0, from: prepared, isCancelled: { false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.path + "_immersal.zip"))
        let entries = try unzip(export())
        XCTAssertEqual(direct.png, entries["frame_0007.png"])
        var archived = try json(entries, index: 7)
        archived.removeValue(forKey: "imagePath")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: direct.metadata) as? NSDictionary)
        XCTAssertEqual(metadata, archived as NSDictionary)
        XCTAssertNil(metadata["token"])
        XCTAssertEqual(prepared.fingerprint, try exporter.prepareUpload(scanDirectory: scan, isCancelled: { false }).fingerprint)
    }

    func testUploadPreflightRejectsBadLaterFrameBeforeSendingAnything() throws {
        try writeScan(frames: [frame(index: 1), frame(index: 2)])
        try Data("broken".utf8).write(to: scan.appendingPathComponent("images/source_2.jpg"))
        XCTAssertThrowsError(try ImmersalScanExporter().prepareUpload(scanDirectory: scan, isCancelled: { false }))
    }

    func testUploadRejectsSourceMutationAfterPreparation() throws {
        try writeScan(frames: [frame(index: 1)])
        let exporter = ImmersalScanExporter()
        let prepared = try exporter.prepareUpload(scanDirectory: scan, isCancelled: { false })
        try Data("changed".utf8).write(to: scan.appendingPathComponent("images/source_1.jpg"))
        XCTAssertThrowsError(try exporter.uploadFrame(at: 0, from: prepared, isCancelled: { false }))
    }

    func testArchiveHasOnlyRootImageJSONPairsAndVerifiedCRC() throws {
        try writeScan(frames: [frame(index: 7, run: 123), frame(index: 42, run: 123)])
        let exporter = ImmersalScanExporter()
        XCTAssertNil(exporter.availability(scanDirectory: scan))
        var messages: [String] = []
        let zip = try exporter.export(scanDirectory: scan, progress: { messages.append($0) }, isCancelled: { false })
        XCTAssertEqual(zip, root.appendingPathComponent("scan_fixture_immersal.zip"))
        let entries = try unzip(zip)
        XCTAssertEqual(Set(entries.keys), ["frame_0007.png", "frame_0007.json", "frame_0042.png", "frame_0042.json"])
        for count in [1, 2] {
            XCTAssertTrue(messages.contains { $0.contains("正在转换第 \(count)/2 帧") })
            XCTAssertTrue(messages.contains { $0.contains("正在打包第 \(count)/2 帧") })
        }
        let json = try json(entries, index: 7)
        XCTAssertEqual(Set(json.keys), Set(["imagePath", "run", "index", "anchor", "fx", "fy", "ox", "oy", "px", "py", "pz", "r00", "r01", "r02", "r10", "r11", "r12", "r20", "r21", "r22", "latitude", "longitude", "altitude"]))
        XCTAssertEqual(json["imagePath"] as? String, "frame_0007.png")
        XCTAssertEqual(json["run"] as? Int, 123)
        XCTAssertEqual(json["index"] as? Int, 7)
        XCTAssertEqual(json["anchor"] as? Bool, false)
        XCTAssertEqual(try number(json, "fx"), 55.25)
        XCTAssertEqual(try number(json, "fy"), 53.75)
        XCTAssertEqual(try number(json, "ox"), 21.4)
        XCTAssertEqual(try number(json, "oy"), 14.8)
        XCTAssertEqual(try number(json, "r00"), 1)
        XCTAssertEqual(try number(json, "r11"), -1)
        XCTAssertEqual(try number(json, "r22"), -1)
        for key in ["latitude", "longitude", "altitude"] { XCTAssertEqual(try number(json, key), 0) }
    }

    func testPNGRetainsRawJPEGDimensionsAndAsymmetricCornerPixels() throws {
        try writeScan(frames: [frame(index: 0)])
        let original = try Data(contentsOf: scan.appendingPathComponent("images/source_0.jpg"))
        let entries = try unzip(export())
        let png = try XCTUnwrap(entries["frame_0000.png"])
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(png[24], 8, "PNG must use 8-bit channels")
        XCTAssertEqual(png[25], 2, "PNG must be RGB without alpha")
        let sourceImage = try decode(original)
        let outputImage = try decode(png)
        XCTAssertEqual(outputImage.width, width)
        XCTAssertEqual(outputImage.height, height)
        let sourcePixels = try rgba(sourceImage)
        let outputPixels = try rgba(outputImage)
        for (x, y) in [(3, 3), (width - 4, 3), (3, height - 4), (width - 4, height - 4)] {
            let offset = (y * width + x) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Double(outputPixels[offset + channel]), Double(sourcePixels[offset + channel]), accuracy: 2)
            }
        }
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try source(png), 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }

    func testDoublePrecisionProjectionMatchesForRotationsAndTranslations() throws {
        var transforms: [[Double]] = [identity,
            transform(x: .pi / 2, y: 0, z: 0, position: [0, 0, 0]),
            transform(x: 0, y: .pi / 2, z: 0, position: [0, 0, 0]),
            transform(x: 0, y: 0, z: .pi / 2, position: [0, 0, 0]),
            transform(x: 0.31, y: -0.58, z: 1.03, position: [4.2, -1.7, 8.3])]
        for i in 0..<25 {
            let value = Double(i)
            let position: [Double] = [value * 0.71 - 2, value * -0.27, value * 0.31 + 1]
            transforms.append(transform(x: value * 0.13, y: value * -0.17, z: value * 0.23, position: position))
        }
        let frames = transforms.enumerated().map { i, transform -> [String: Any] in
            var value = frame(index: i, run: 345)
            value["transform"] = transform
            return value
        }
        try writeScan(frames: frames)
        let entries = try unzip(export())
        for frame in frames {
            let index = try XCTUnwrap(frame["index"] as? Int)
            let t = try XCTUnwrap(frame["transform"] as? [Double])
            let pose = try json(entries, index: index)
            XCTAssertEqual(try number(pose, "px"), t[12])
            XCTAssertEqual(try number(pose, "py"), t[13])
            XCTAssertEqual(try number(pose, "pz"), t[14])
            let rotation = try (0..<3).map { row in
                try (0..<3).map { col in try number(pose, "r\(row)\(col)") }
            }
            for col in 0..<3 {
                for other in 0..<3 {
                    let dot = (0..<3).reduce(0.0) { $0 + rotation[$1][col] * rotation[$1][other] }
                    XCTAssertEqual(dot, col == other ? 1 : 0, accuracy: 1e-12)
                }
            }
            let r = rotation
            let determinant = r[0][0] * (r[1][1] * r[2][2] - r[1][2] * r[2][1])
                - r[0][1] * (r[1][0] * r[2][2] - r[1][2] * r[2][0])
                + r[0][2] * (r[1][0] * r[2][1] - r[1][1] * r[2][0])
            XCTAssertEqual(determinant, 1, accuracy: 1e-12)
            for (u, v, depth) in [(5.5, 4.25, 0.7), (21.4, 14.8, 3.0), (43.1, 28.5, 8.4)] {
                // Construct a world point using ARKit's +X right, +Y up, -Z forward convention.
                let camera = [(u - 21.4) * depth / 55.25, -(v - 14.8) * depth / 53.75, -depth]
                let world = (0..<3).map { row in
                    t[row] * camera[0] + t[4 + row] * camera[1] + t[8 + row] * camera[2] + t[12 + row]
                }
                let relative = (0..<3).map { world[$0] - t[12 + $0] }
                // Independently invert the exported camera-to-world rotation using its transpose.
                let cv = try (0..<3).map { col -> Double in
                    try (0..<3).reduce(0) { total, row in total + (try number(pose, "r\(row)\(col)")) * relative[row] }
                }
                XCTAssertGreaterThan(cv[2], 0)
                let originalDistance = relative.reduce(0.0) { $0 + $1 * $1 }
                let convertedDistance = cv.reduce(0.0) { $0 + $1 * $1 }
                XCTAssertEqual(convertedDistance, originalDistance, accuracy: 1e-10,
                               "The conversion must preserve metric distance")
                for row in 0..<3 {
                    let reconstructed = (0..<3).reduce(t[12 + row]) { $0 + rotation[row][$1] * cv[$1] }
                    XCTAssertEqual(reconstructed, world[row], accuracy: 1e-12,
                                   "Camera/world conversion must remain invertible")
                }
                XCTAssertEqual(try number(pose, "fx") * cv[0] / cv[2] + number(pose, "ox"), u, accuracy: 1e-4)
                XCTAssertEqual(try number(pose, "fy") * cv[1] / cv[2] + number(pose, "oy"), v, accuracy: 1e-4)
            }
        }
    }

    func testLegacyCompleteManifestDerivesStablePositive31BitRun() throws {
        try writeScan(frames: [frame(index: 4), frame(index: 9)])
        let first = try unzip(export())
        let second = try unzip(export())
        let run = try XCTUnwrap(try json(first, index: 4)["run"] as? Int)
        XCTAssertGreaterThan(run, 0)
        XCTAssertLessThanOrEqual(run, Int(Int32.max))
        XCTAssertEqual(try json(first, index: 9)["run"] as? Int, run)
        XCTAssertEqual(try json(second, index: 4)["run"] as? Int, run)
        XCTAssertEqual(first, second, "Repeated export must preserve image and metadata payloads")
    }

    func testRejectsPersistedRunOutsidePositive31BitRange() throws {
        for run in [0, -1, Int(Int32.max) + 1] {
            try writeScan(frames: [frame(index: 0, run: run)])
            XCTAssertNotNil(ImmersalScanExporter().availability(scanDirectory: scan))
            XCTAssertThrowsError(try export())
        }
    }

    func testStoredGPSIsPreservedAndUnavailableAltitudeBecomesZero() throws {
        var valid = frame(index: 0)
        valid["location"] = ["latitude": 31.2, "longitude": 121.5, "altitude": 23.75,
                             "timestamp": 1_800_000_000.0, "horizontalAccuracy": 8.0, "verticalAccuracy": 5.0]
        var noAltitude = frame(index: 1)
        noAltitude["location"] = ["latitude": -22.0, "longitude": -179.0, "altitude": 999.0,
                                  "timestamp": 1_800_000_000.0, "horizontalAccuracy": 10.0, "verticalAccuracy": -1.0]
        var invalid = frame(index: 2)
        invalid["location"] = ["latitude": 91.0, "longitude": 121.5, "altitude": 23.0,
                              "timestamp": 1_800_000_000.0, "horizontalAccuracy": 5.0, "verticalAccuracy": 5.0]
        try writeScan(frames: [valid, noAltitude, invalid])
        let entries = try unzip(export())
        let first = try json(entries, index: 0)
        XCTAssertEqual(try number(first, "latitude"), 31.2)
        XCTAssertEqual(try number(first, "longitude"), 121.5)
        XCTAssertEqual(try number(first, "altitude"), 23.75)
        let second = try json(entries, index: 1)
        XCTAssertEqual(try number(second, "latitude"), -22)
        XCTAssertEqual(try number(second, "altitude"), 0)
        let third = try json(entries, index: 2)
        XCTAssertEqual(try number(third, "latitude"), 0)
        XCTAssertEqual(try number(third, "longitude"), 0)
        XCTAssertEqual(try number(third, "altitude"), 0)
    }

    func testRejectsIncompleteLegacyManifestAndWrongCoordinateContract() throws {
        for key in ["schemaVersion", "coordinateSystem", "matrixLayout", "units"] {
            var value = manifest(frames: [frame(index: 0)])
            value.removeValue(forKey: key)
            try writeManifest(value)
            XCTAssertNotNil(ImmersalScanExporter().availability(scanDirectory: scan), key)
            XCTAssertThrowsError(try export(), key)
        }
        for (key, wrong) in [("schemaVersion", 2 as Any), ("coordinateSystem", "opencv" as Any),
                             ("matrixLayout", "row-major" as Any), ("units", "centimeters" as Any)] {
            var value = manifest(frames: [frame(index: 0)])
            value[key] = wrong
            try writeManifest(value)
            XCTAssertThrowsError(try export(), key)
        }
        try writeScan(frames: [])
        XCTAssertThrowsError(try export())
    }

    func testRejectsMissingFrameMetadataInvalidIntrinsicsAndDuplicateIdentifiers() throws {
        for key in ["imageOrientation", "image", "intrinsics", "timestamp", "transform"] {
            var value = frame(index: 0)
            value.removeValue(forKey: key)
            try writeScan(frames: [value])
            XCTAssertThrowsError(try export(), key)
        }
        var portrait = frame(index: 0)
        portrait["imageOrientation"] = "portrait"
        try writeScan(frames: [portrait])
        XCTAssertThrowsError(try export())
        portrait["imageOrientation"] = "landscapeLeft"
        try writeScan(frames: [portrait])
        XCTAssertThrowsError(try export())
        var badIntrinsics = frame(index: 0)
        badIntrinsics["intrinsics"] = ["fx": 0, "fy": 50, "cx": 24, "cy": 16]
        try writeScan(frames: [badIntrinsics])
        XCTAssertThrowsError(try export())
        try writeScan(frames: [frame(index: 0), frame(index: 0)])
        XCTAssertThrowsError(try export())
        var duplicateImage = frame(index: 1)
        duplicateImage["imageFile"] = "images/source_0.jpg"
        try writeScan(frames: [frame(index: 0), duplicateImage])
        XCTAssertThrowsError(try export())
    }

    func testRejectsNonAffineReflectedAndNonOrthonormalTransforms() throws {
        var invalid: [[Double]] = [Array(identity.prefix(15))]
        var affine = identity; affine[3] = 0.1; invalid.append(affine)
        var reflected = identity; reflected[0] = -1; invalid.append(reflected)
        var scale = identity; scale[0] = 2; invalid.append(scale)
        var shear = identity; shear[4] = 0.05; invalid.append(shear)
        for transform in invalid {
            var value = frame(index: 0); value["transform"] = transform
            try writeScan(frames: [value])
            XCTAssertThrowsError(try export())
        }
    }

    func testRejectsMissingCorruptAndDimensionMismatchedImagesWithoutPublishing() throws {
        try writeScan(frames: [frame(index: 0)])
        let sourceURL = scan.appendingPathComponent("images/source_0.jpg")
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertNotNil(ImmersalScanExporter().availability(scanDirectory: scan))
        XCTAssertThrowsError(try export())
        try Data([1, 2, 3]).write(to: sourceURL)
        XCTAssertNil(ImmersalScanExporter().availability(scanDirectory: scan), "Availability must not decode pixels")
        XCTAssertThrowsError(try export())
        var mismatch = frame(index: 0)
        mismatch["image"] = ["width": width + 1, "height": height]
        try writeScan(frames: [mismatch])
        XCTAssertThrowsError(try export())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoTemporaryArchive()
    }

    func testRejectsTraversalAbsoluteAndSymlinkImagePaths() throws {
        try writeScan(frames: [frame(index: 0)])
        let outside = root.appendingPathComponent("outside.jpg")
        try jpeg().write(to: outside)
        for path in ["../outside.jpg", outside.path, "images/../../outside.jpg"] {
            var value = frame(index: 0); value["imageFile"] = path
            try writeManifest(manifest(frames: [value]))
            XCTAssertNotNil(ImmersalScanExporter().availability(scanDirectory: scan))
            XCTAssertThrowsError(try export())
        }
        let link = scan.appendingPathComponent("images/linked.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var linked = frame(index: 0); linked["imageFile"] = "images/linked.jpg"
        try writeManifest(manifest(frames: [linked]))
        XCTAssertThrowsError(try export())
    }

    func testMissingFrameFileReasonIdentifiesOriginalFrameIndex() throws {
        try writeScan(frames: [frame(index: 7)])
        try FileManager.default.removeItem(at: scan.appendingPathComponent("images/source_7.jpg"))
        let reason = try XCTUnwrap(ImmersalScanExporter().availability(scanDirectory: scan))
        XCTAssertTrue(reason.contains("第 7 帧"), reason)
    }

    func testMissingMetadataReasonIdentifiesOriginalFrameIndex() throws {
        var incomplete = frame(index: 42)
        incomplete.removeValue(forKey: "intrinsics")
        try writeScan(frames: [frame(index: 7), incomplete])
        let reason = try XCTUnwrap(ImmersalScanExporter().availability(scanDirectory: scan))
        XCTAssertTrue(reason.contains("第 42 帧"), reason)
    }

    func testCancellationCleansPartialArchiveAndPreservesPreviousGoodOutput() throws {
        try writeScan(frames: [frame(index: 0), frame(index: 1)])
        _ = try export()
        let previous = try Data(contentsOf: output)
        var cancelled = false
        XCTAssertThrowsError(try ImmersalScanExporter().export(scanDirectory: scan, progress: { message in
            if message.contains("正在打包第 2/2 帧") { cancelled = true }
        }, isCancelled: { cancelled })) { error in
            guard case ImmersalScanExporter.ExportError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: output), previous)
        try assertNoTemporaryArchive()
    }

    func testCancellationIsCheckedDuringMetadataValidation() throws {
        try writeScan(frames: [frame(index: 0), frame(index: 1)])
        try FileManager.default.removeItem(at: scan.appendingPathComponent("images/source_1.jpg"))
        var checks = 0
        XCTAssertThrowsError(try ImmersalScanExporter().export(scanDirectory: scan, progress: { _ in }, isCancelled: {
            checks += 1
            return checks > 1
        })) { error in
            guard case ImmersalScanExporter.ExportError.cancelled = error else {
                return XCTFail("Cancellation should stop metadata validation before later file errors: \(error)")
            }
        }
        try assertNoTemporaryArchive()
    }

    func testDiskWriteFailurePreservesPreviousGoodOutput() throws {
        try writeScan(frames: [frame(index: 0)])
        _ = try export()
        let previous = try Data(contentsOf: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try export())
        XCTAssertEqual(try Data(contentsOf: output), previous)
        try assertNoTemporaryArchive()
    }

    func testInvalidLaterFrameAndPublishingFailurePreservePreviousGoodOutput() throws {
        try writeScan(frames: [frame(index: 0), frame(index: 1)])
        _ = try export()
        let previous = try Data(contentsOf: output)
        try Data([0, 1, 2]).write(to: scan.appendingPathComponent("images/source_1.jpg"))
        XCTAssertThrowsError(try export())
        XCTAssertEqual(try Data(contentsOf: output), previous)
        try assertNoTemporaryArchive()
        try writeScan(frames: [frame(index: 0)])
        let failing = ImmersalScanExporter(publish: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try failing.export(scanDirectory: scan, progress: { _ in }, isCancelled: { false }))
        XCTAssertEqual(try Data(contentsOf: output), previous)
        try assertNoTemporaryArchive()
    }

    // MARK: Fixture and independent decoding helpers

    private var output: URL { root.appendingPathComponent("scan_fixture_immersal.zip") }

    private func export() throws -> URL {
        try ImmersalScanExporter().export(scanDirectory: scan, progress: { _ in }, isCancelled: { false })
    }

    private func frame(index: Int, run: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["index": index, "timestamp": Double(index) * 0.5,
            "imageFile": "images/source_\(index).jpg", "transform": identity,
            "imageOrientation": "landscapeRight", "image": ["width": width, "height": height],
            "intrinsics": ["fx": 55.25, "fy": 53.75, "cx": 21.4, "cy": 14.8]]
        if let run { value["run"] = run }
        return value
    }

    private func manifest(frames: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 1, "coordinateSystem": "arkit-world", "matrixLayout": "arkit-column-major",
         "units": "meters", "frames": frames]
    }

    private func writeManifest(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: scan.appendingPathComponent("manifest.json"))
    }

    private func writeScan(frames: [[String: Any]]) throws {
        let image = try jpeg()
        for frame in frames {
            if let index = frame["index"] as? Int {
                try image.write(to: scan.appendingPathComponent("images/source_\(index).jpg"))
            }
        }
        try writeManifest(manifest(frames: frames))
    }

    private func jpeg() throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        let colors: [[UInt8]] = [[230, 25, 45], [20, 210, 65], [30, 50, 220], [230, 195, 20]]
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                for c in 0..<3 { pixels[(y * width + x) * 3 + c] = color[c] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                         bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [],
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        // EXIF requests a rotation. The export contract is explicitly the retained raw pixels.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0,
                                                       kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func decode(_ data: Data) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(try source(data), 0, nil))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func unzip(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            XCTAssertEqual(entry.type, .file)
            XCTAssertFalse(entry.path.contains("/"))
            var bytes = Data()
            let checksum = try archive.extract(entry) { bytes.append($0) }
            XCTAssertEqual(checksum, entry.checksum)
            XCTAssertEqual(crc32(bytes), entry.checksum)
            XCTAssertNil(result.updateValue(bytes, forKey: entry.path))
        }
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }

    private func json(_ entries: [String: Data], index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(entries[String(format: "frame_%04d.json", index)])) as? [String: Any])
    }

    private func number(_ json: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(json[key] as? Double, key)
    }

    private func assertNoTemporaryArchive(file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), FileManager.default.fileExists(atPath: output.path) ? ["scan_fixture", "scan_fixture_immersal.zip"] : ["scan_fixture"], file: file, line: line)
    }

    private func transform(x: Double, y: Double, z: Double, position: [Double]) -> [Double] {
        let cx = cos(x), sx = sin(x), cy = cos(y), sy = sin(y), cz = cos(z), sz = sin(z)
        // Rz * Ry * Rx, returned as the persisted column-major ARKit matrix.
        return [cz * cy, sz * cy, -sy, 0,
                cz * sy * sx - sz * cx, sz * sy * sx + cz * cx, cy * sx, 0,
                cz * sy * cx + sz * sx, sz * sy * cx - cz * sx, cy * cx, 0,
                position[0], position[1], position[2], 1]
    }
}
