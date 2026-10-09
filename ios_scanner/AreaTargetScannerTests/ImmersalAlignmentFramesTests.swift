import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import AreaTargetScanner

final class ImmersalAlignmentFramesTests: XCTestCase {
    private var root: URL!
    private var scan: URL!
    private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersalAlignmentFramesTests-\(UUID().uuidString)")
        scan = root.appendingPathComponent("scan_fixture")
        try FileManager.default.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSelectsEightEvenlyDistributedFramesIncludingBothEnds() throws {
        try writeScan(frames: (0..<20).map { frame(index: $0) })
        let selected = try ImmersalAlignmentFrames.select(scanDirectory: scan)
        XCTAssertEqual(selected.map(\.index), [0, 3, 5, 8, 11, 14, 16, 19])
        XCTAssertEqual(Set(selected.map(\.imageURL)).count, 8)
    }

    func testSelectionUsesOrderedFrameIndicesAndKeepsSmallValidScan() throws {
        try writeScan(frames: [frame(index: 9), frame(index: 2), frame(index: 6)])
        XCTAssertEqual(try ImmersalAlignmentFrames.select(scanDirectory: scan).map(\.index), [2, 6, 9])
    }

    func testColumnMajorPoseAndPerFrameIntrinsicsAreRetainedWithoutAxisConversion() throws {
        // 90 degrees around Z, followed by translation in the scan world.
        let transform: [Double] = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 4, 5, 6, 1]
        var first = frame(index: 0)
        first["transform"] = transform
        first["intrinsics"] = ["fx": 2.25, "fy": 3.5, "cx": 0.75, "cy": 1.25]
        try writeScan(frames: [first, frame(index: 1), frame(index: 2)])
        let selected = try XCTUnwrap(ImmersalAlignmentFrames.select(scanDirectory: scan).first)
        XCTAssertEqual(selected.width, 3)
        XCTAssertEqual(selected.height, 2)
        XCTAssertEqual(selected.intrinsics, SIMD4(2.25, 3.5, 0.75, 1.25))
        XCTAssertEqual(selected.scanFromCamera * SIMD4<Float>(1, 0, 0, 1), SIMD4(4, 6, 6, 1))
        XCTAssertEqual(selected.scanFromCamera.columns.3, SIMD4(4, 5, 6, 1))
    }

    func testGrayscaleIsTightlyPackedTopRowFirstAndIgnoresEXIFRotation() throws {
        let rgb: [UInt8] = [0, 0, 0, 255, 255, 255, 0, 0, 0,
                            255, 255, 255, 0, 0, 0, 255, 255, 255]
        try writeScan(frames: (0..<3).map { frame(index: $0) }, image: encodedImage(rgb: rgb, orientation: 6))
        let selected = try XCTUnwrap(ImmersalAlignmentFrames.select(scanDirectory: scan).first)
        let pixels = try ImmersalAlignmentFrames.pixels(for: selected)
        XCTAssertEqual(pixels.count, 6, "A 3×2 frame has six bytes, without row padding")
        XCTAssertEqual(Array(pixels), [0, 255, 0, 255, 0, 255], "Retain raw sensor row order, matching the exporter CGContext draw")
    }

    func testColorToGrayConversionRetainsAsymmetricRowsAndUsesLuminance() throws {
        let rgb: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 0, 0,
                            0, 255, 0, 0, 0, 255, 64, 64, 64]
        try writeScan(frames: (0..<3).map { frame(index: $0) }, image: encodedImage(rgb: rgb))
        let selected = try XCTUnwrap(ImmersalAlignmentFrames.select(scanDirectory: scan).first)
        let values = Array(try ImmersalAlignmentFrames.pixels(for: selected))
        XCTAssertEqual(values.count, 6)
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 255)
        XCTAssertGreaterThan(values[3], values[2], "Green must be brighter than red in grayscale")
        XCTAssertGreaterThan(values[2], values[4], "Red must be brighter than blue in grayscale")
        XCTAssertGreaterThan(values[5], 0)
        XCTAssertLessThan(values[5], values[2])
    }

    func testOriginalJPEGCanBeDecodedWithoutApplyingItsEXIFOrientation() throws {
        try writeScan(frames: (0..<3).map { frame(index: $0) }, image: encodedImage(type: .jpeg, orientation: 6))
        let selected = try XCTUnwrap(ImmersalAlignmentFrames.select(scanDirectory: scan).first)
        XCTAssertEqual(selected.width, 3)
        XCTAssertEqual(selected.height, 2)
        XCTAssertEqual(try ImmersalAlignmentFrames.pixels(for: selected).count, 6)
    }

    func testAtLeastThreeDistinctFrameIndicesAreRequired() throws {
        for frames in [[], [frame(index: 0)], [frame(index: 0), frame(index: 1)],
                       [frame(index: 0), frame(index: 1), frame(index: 1)]] {
            try writeScan(frames: frames)
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
    }

    func testVersionCoordinateSystemLayoutAndUnitsMustMatchSchema() throws {
        try writeScan(frames: (0..<3).map { frame(index: $0) })
        for (key, invalid) in [("schemaVersion", 2 as Any), ("coordinateSystem", "unity-world" as Any),
                               ("matrixLayout", "row-major" as Any), ("units", "centimeters" as Any)] {
            var value = manifest(frames: (0..<3).map { frame(index: $0) })
            value[key] = invalid
            try writeManifest(value)
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan), key)
        }
    }

    func testMixedRunsRejectUnconfirmedScanCoordinateWorldAndMissingRunMeansZero() throws {
        try writeScan(frames: [frame(index: 0), frame(index: 1, run: 0), frame(index: 2)])
        XCTAssertEqual(try ImmersalAlignmentFrames.select(scanDirectory: scan).count, 3)
        for runs in [[0, 1, 0], [7, 7, 8]] {
            try writeScan(frames: runs.enumerated().map { frame(index: $0.offset, run: $0.element) })
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("无法确认扫描坐标"), error.localizedDescription)
            }
        }
        try writeScan(frames: (0..<3).map { frame(index: $0, run: 7) })
        XCTAssertEqual(try ImmersalAlignmentFrames.select(scanDirectory: scan).count, 3)
    }

    func testInvalidLaterFrameIsRejectedEvenWhenNotSelectedForEightSamples() throws {
        var values = (0..<20).map { frame(index: $0) }
        values[1]["imageOrientation"] = "portrait"
        try writeScan(frames: values)
        XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
    }

    func testInvalidDimensionsIntrinsicsAndImageDimensionMismatchAreRejected() throws {
        let invalidDimensions = [["width": 0, "height": 2], ["width": 4097, "height": 2],
                                 ["width": 4096, "height": 4096], ["width": Int.max, "height": 2],
                                 ["width": 4, "height": 2]]
        for dimensions in invalidDimensions {
            var value = frame(index: 0); value["image"] = dimensions
            try writeScan(frames: [value, frame(index: 1), frame(index: 2)])
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
        for intrinsics in [["fx": 0.0, "fy": 2, "cx": 1, "cy": 1],
                           ["fx": 2.0, "fy": -1, "cx": 1, "cy": 1],
                           ["fx": 2.0, "fy": 2, "cx": -0.1, "cy": 1],
                           ["fx": 2.0, "fy": 2, "cx": 3, "cy": 1],
                           ["fx": 2.0, "fy": 2, "cx": 1, "cy": 2],
                           ["fx": 1e100, "fy": 2, "cx": 1, "cy": 1]] {
            var value = frame(index: 0); value["intrinsics"] = intrinsics
            try writeScan(frames: [value, frame(index: 1), frame(index: 2)])
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
    }

    func testPoseRejectsScaleReflectionNonAffineAndNonfiniteOrOverflowNumbers() throws {
        var scale = identity; scale[0] = 2
        var reflection = identity; reflection[0] = -1
        var nonAffine = identity; nonAffine[3] = 0.2
        var hugeTranslation = identity; hugeTranslation[12] = 1e100
        for transform in [Array(identity.dropLast()), scale, reflection, nonAffine, hugeTranslation] {
            var value = frame(index: 0); value["transform"] = transform
            try writeScan(frames: [value, frame(index: 1), frame(index: 2)])
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
        try writeScan(frames: (0..<3).map { frame(index: $0) })
        let json = try String(contentsOf: scan.appendingPathComponent("manifest.json"), encoding: .utf8)
        let invalidJSON = json.replacingOccurrences(of: "\"fx\":2", with: "\"fx\":1e999")
        XCTAssertNotEqual(invalidJSON, json)
        try invalidJSON.write(to: scan.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
    }

    func testTraversalAbsoluteDirectoryAndImageSymlinksAreRejected() throws {
        try writeScan(frames: (0..<3).map { frame(index: $0) })
        let outside = root.appendingPathComponent("outside.png")
        try encodedImage().write(to: outside)
        for path in ["../outside.png", outside.path, "images/../../outside.png", "images\\frame_0.png", "images/./frame_0.png"] {
            var value = frame(index: 0); value["imageFile"] = path
            try writeManifest(manifest(frames: [value, frame(index: 1), frame(index: 2)]))
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
        try FileManager.default.createSymbolicLink(at: scan.appendingPathComponent("images/linked.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: scan.appendingPathComponent("linked-images"), withDestinationURL: scan.appendingPathComponent("images"))
        for path in ["images/linked.png", "linked-images/frame_0.png"] {
            var value = frame(index: 0); value["imageFile"] = path
            try writeManifest(manifest(frames: [value, frame(index: 1), frame(index: 2)]))
            XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        }
    }

    func testManifestSymlinkAndCorruptImageAreRejected() throws {
        try writeScan(frames: (0..<3).map { frame(index: $0) })
        let manifestURL = scan.appendingPathComponent("manifest.json")
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: manifestURL, to: outside)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outside)
        XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
        try FileManager.default.removeItem(at: manifestURL)
        try writeManifest(manifest(frames: (0..<3).map { frame(index: $0) }))
        try Data([1, 2, 3]).write(to: scan.appendingPathComponent("images/frame_2.png"))
        XCTAssertThrowsError(try ImmersalAlignmentFrames.select(scanDirectory: scan))
    }

    func testPixelsRevalidatesFileContainmentAndDimensionsAfterSelection() throws {
        try writeScan(frames: (0..<3).map { frame(index: $0) })
        let selected = try XCTUnwrap(ImmersalAlignmentFrames.select(scanDirectory: scan).first)
        try encodedImage(width: 2, height: 3).write(to: selected.imageURL)
        XCTAssertThrowsError(try ImmersalAlignmentFrames.pixels(for: selected))
        let outside = root.appendingPathComponent("outside.png")
        try encodedImage().write(to: outside)
        try FileManager.default.removeItem(at: selected.imageURL)
        try FileManager.default.createSymbolicLink(at: selected.imageURL, withDestinationURL: outside)
        XCTAssertThrowsError(try ImmersalAlignmentFrames.pixels(for: selected))
    }

    private func frame(index: Int, run: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["index": index, "imageFile": "images/frame_\(index).png", "transform": identity,
                                   "image": ["width": 3, "height": 2],
                                   "intrinsics": ["fx": 2.0, "fy": 2.0, "cx": 1.0, "cy": 1.0],
                                   "imageOrientation": "landscapeRight"]
        if let run { value["run"] = run }
        return value
    }

    private func manifest(frames: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 1, "coordinateSystem": "arkit-world", "matrixLayout": "arkit-column-major", "units": "meters", "frames": frames]
    }

    private func writeManifest(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: scan.appendingPathComponent("manifest.json"))
    }

    private func writeScan(frames: [[String: Any]], image: Data? = nil) throws {
        let bytes = try image ?? encodedImage()
        for value in frames {
            if let index = value["index"] as? Int { try bytes.write(to: scan.appendingPathComponent("images/frame_\(index).png")) }
        }
        try writeManifest(manifest(frames: frames))
    }

    private func encodedImage(width: Int = 3, height: Int = 2, rgb: [UInt8]? = nil,
                              type: UTType = .png, orientation: Int = 1) throws -> Data {
        let values = rgb ?? [UInt8](repeating: 128, count: width * height * 3)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                        bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [],
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0,
                                                       kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
