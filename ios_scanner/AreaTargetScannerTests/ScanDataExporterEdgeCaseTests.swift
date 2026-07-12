import XCTest
@testable import AreaTargetScanner

/// Extended edge case tests for ScanDataExporter.
///
/// Validates:
/// - ExportError types and descriptions
/// - PLY edge cases (malformed vertices, large datasets)
/// - Poses JSON edge cases (empty poses, single pose)
/// - exportAll with no meshAnchors (texture mapping skipped)
/// - exportAll with empty images (texture mapping skipped)
/// - Idempotent export (overwrite existing files)
final class ScanDataExporterEdgeCaseTests: XCTestCase {

    private var exporter: ScanDataExporter!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        exporter = ScanDataExporter()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExporterEdge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - ExportError Type Tests

    func testExportError_directoryCreationFailed_includesPath() {
        let error = ScanDataExporter.ExportError.directoryCreationFailed("/bad/path")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("/bad/path"))
    }

    func testExportError_plyWriteFailed_includesReason() {
        let error = ScanDataExporter.ExportError.plyWriteFailed("disk full")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("disk full"))
    }

    func testExportError_jsonEncodeFailed_includesReason() {
        let error = ScanDataExporter.ExportError.jsonEncodeFailed("invalid data")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("invalid data"))
    }

    func testExportError_imageWriteFailed_includesFilename() {
        let error = ScanDataExporter.ExportError.imageWriteFailed("frame_0001.jpg")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("frame_0001.jpg"))
    }

    func testAllExportErrors_haveNonNilDescriptions() {
        let errors: [ScanDataExporter.ExportError] = [
            .directoryCreationFailed("test"),
            .plyWriteFailed("test"),
            .jsonEncodeFailed("test"),
            .imageWriteFailed("test")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - PLY Edge Cases

    func testWritePLY_vertexWithLessThan9Components_skipped() throws {
        let vertices: [[Float]] = [
            [1.0, 2.0, 3.0, 0.5, 0.5, 0.5, 0, 1, 0],  // valid
            [1.0, 2.0],                                     // too short, skipped by guard
            [4.0, 5.0, 6.0, 0.5, 0.5, 0.5, 0, 0, 1],  // valid
        ]
        let plyURL = tempDir.appendingPathComponent("edge.ply")

        try exporter.writePLY(vertices: vertices, to: plyURL)

        let content = try String(contentsOf: plyURL, encoding: .utf8)
        // NOTE: Header says "element vertex 3" (input array count) but only 2 data lines
        // are written because the short vertex is skipped by `guard vertex.count >= 9`.
        // This is a known inconsistency in the current implementation.
        XCTAssertTrue(content.contains("element vertex 3"),
            "Header uses vertices.count which includes the short vertex")
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let headerEnd = lines.firstIndex(of: "end_header")!
        let dataLines = lines[(headerEnd + 1)...]
        XCTAssertEqual(dataLines.count, 2,
            "Only 2 valid vertices should produce data lines (short vertex skipped)")
    }

    func testWritePLY_colorClamping_negativeValues() throws {
        let vertices: [[Float]] = [
            [0, 0, 0, -0.5, 1.5, 0.5, 0, 1, 0]  // negative and >1 color values
        ]
        let plyURL = tempDir.appendingPathComponent("clamp.ply")

        try exporter.writePLY(vertices: vertices, to: plyURL)

        let content = try String(contentsOf: plyURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let dataLine = lines[13]
        let components = dataLine.components(separatedBy: " ")
        // UInt8(clamping:) clamps to 0...255
        XCTAssertEqual(components[3], "0", "Negative color should clamp to 0")
        // 1.5 * 255 = 382, clamped to 255
        XCTAssertEqual(components[4], "255", "Color > 1.0 should clamp to 255")
    }

    // MARK: - Poses JSON Edge Cases

    func testWritePosesJSON_emptyPoses_producesEmptyFrames() throws {
        let posesURL = tempDir.appendingPathComponent("empty_poses.json")

        try exporter.writePosesJSON(poses: [], to: posesURL)

        let data = try Data(contentsOf: posesURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = json["frames"] as! [[String: Any]]
        XCTAssertEqual(frames.count, 0)
    }

    func testWritePosesJSON_singlePose_correctStructure() throws {
        let pose = CameraPose(
            timestamp: 1.5,
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            imageFilename: "frame_0000.jpg"
        )
        let posesURL = tempDir.appendingPathComponent("single_pose.json")

        try exporter.writePosesJSON(poses: [pose], to: posesURL)

        let data = try Data(contentsOf: posesURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = json["frames"] as! [[String: Any]]
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["index"] as? Int, 0)
        XCTAssertEqual(frames[0]["timestamp"] as? Double, 1.5)
        XCTAssertEqual(frames[0]["imageFile"] as? String, "images/frame_0000.jpg")
    }

    // MARK: - Intrinsics Edge Cases

    func testWriteIntrinsicsJSON_roundTrip_preservesValues() throws {
        let intrinsics = CameraIntrinsics(fx: 1000.5, fy: 999.5, cx: 640.0, cy: 480.0, width: 1280, height: 960)
        let url = tempDir.appendingPathComponent("intrinsics.json")

        try exporter.writeIntrinsicsJSON(intrinsics: intrinsics, to: url)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CameraIntrinsics.self, from: data)
        XCTAssertEqual(decoded.fx, 1000.5, accuracy: 0.01)
        XCTAssertEqual(decoded.fy, 999.5, accuracy: 0.01)
        XCTAssertEqual(decoded.cx, 640.0, accuracy: 0.01)
        XCTAssertEqual(decoded.cy, 480.0, accuracy: 0.01)
        XCTAssertEqual(decoded.width, 1280)
        XCTAssertEqual(decoded.height, 960)
    }

    // MARK: - Image Export Edge Cases

    func testWriteImages_emptyArray_createsDirectoryOnly() throws {
        let imagesDir = tempDir.appendingPathComponent("images")

        try exporter.writeImages(images: [], to: imagesDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path)
        XCTAssertEqual(contents.count, 0)
    }

    func testWriteImages_overwriteExisting_succeeds() throws {
        let imagesDir = tempDir.appendingPathComponent("images")
        let images = [CapturedImage(imageData: Data([0xFF, 0xD8]), filename: "test.jpg")]

        // Write once
        try exporter.writeImages(images: images, to: imagesDir)

        // Write again with different data
        let images2 = [CapturedImage(imageData: Data([0xFF, 0xD8, 0xFF, 0xE0]), filename: "test.jpg")]
        try exporter.writeImages(images: images2, to: imagesDir)

        let data = try Data(contentsOf: imagesDir.appendingPathComponent("test.jpg"))
        XCTAssertEqual(data.count, 4, "Second write should overwrite the first")
    }

    // MARK: - exportAll Integration

    func testExportAll_noMeshAnchors_skipsTextureMapping() throws {
        let vertices = (0..<1500).map { i -> [Float] in
            [Float(i) * 0.01, 0, 0, 0.5, 0.5, 0.5, 0, 1, 0]
        }
        let poses = [CameraPose(timestamp: 0, transform: Array(repeating: Float(0), count: 16), imageFilename: "f.jpg")]
        let intrinsics = CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        let images = [CapturedImage(imageData: Data([0xFF, 0xD8]), filename: "f.jpg")]
        let outputPath = tempDir.appendingPathComponent("output").path

        // Should not throw — meshAnchors defaults to empty, texture mapping skipped
        try exporter.exportAll(
            vertices: vertices,
            poses: poses,
            intrinsics: intrinsics,
            images: images,
            outputPath: outputPath
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: (outputPath as NSString).appendingPathComponent("pointcloud.ply")))
        XCTAssertTrue(fm.fileExists(atPath: (outputPath as NSString).appendingPathComponent("poses.json")))
        XCTAssertTrue(fm.fileExists(atPath: (outputPath as NSString).appendingPathComponent("intrinsics.json")))
        // No model.obj since no mesh anchors
        XCTAssertFalse(fm.fileExists(atPath: (outputPath as NSString).appendingPathComponent("model.obj")))
    }

    func testExportAll_emptyImages_skipsTextureMapping() throws {
        let vertices = (0..<100).map { i -> [Float] in
            [Float(i) * 0.01, 0, 0, 0.5, 0.5, 0.5, 0, 1, 0]
        }
        let poses = [CameraPose(timestamp: 0, transform: Array(repeating: Float(0), count: 16), imageFilename: "f.jpg")]
        let intrinsics = CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        let outputPath = tempDir.appendingPathComponent("output2").path

        // Empty images → texture mapping condition (!images.isEmpty) is false
        try exporter.exportAll(
            vertices: vertices,
            poses: poses,
            intrinsics: intrinsics,
            images: [],
            outputPath: outputPath
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: (outputPath as NSString).appendingPathComponent("pointcloud.ply")))
    }

    func testExportAll_idempotent_canRunTwice() throws {
        let vertices = (0..<100).map { i -> [Float] in
            [Float(i) * 0.01, 0, 0, 0.5, 0.5, 0.5, 0, 1, 0]
        }
        let poses = [CameraPose(timestamp: 0, transform: Array(repeating: Float(0), count: 16), imageFilename: "f.jpg")]
        let intrinsics = CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        let images = [CapturedImage(imageData: Data([0xFF, 0xD8]), filename: "f.jpg")]
        let outputPath = tempDir.appendingPathComponent("output3").path

        // Run twice — should not throw on second run
        try exporter.exportAll(vertices: vertices, poses: poses, intrinsics: intrinsics, images: images, outputPath: outputPath)
        try exporter.exportAll(vertices: vertices, poses: poses, intrinsics: intrinsics, images: images, outputPath: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: (outputPath as NSString).appendingPathComponent("pointcloud.ply")))
    }
}
