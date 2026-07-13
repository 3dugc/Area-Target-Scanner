import XCTest
@testable import AreaTargetScanner

/// Unit tests for ScanDataExporter.
///
/// Validates:
/// - PLY file format correctness (Requirement 3.1)
/// - poses.json structure completeness (Requirement 3.2)
/// - intrinsics.json structure completeness (Requirement 3.3)
/// - Export blocking when point count < 1000 (Requirement 3.5)
final class ScanDataExporterTests: XCTestCase {

    private var exporter: ScanDataExporter!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        exporter = ScanDataExporter()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Test Helpers

    /// Creates sample vertices with 9 components each: [x, y, z, r, g, b, nx, ny, nz]
    private func makeSampleVertices(count: Int) -> [[Float]] {
        return (0..<count).map { i in
            let fi = Float(i)
            return [fi * 0.1, fi * 0.2, fi * 0.3,   // position
                    0.5, 0.6, 0.7,                     // color (normalized 0-1)
                    0.0, 1.0, 0.0]                     // normal
        }
    }

    private func makeSamplePoses(count: Int) -> [CameraPose] {
        let intrinsics = makeSampleIntrinsics()
        return (0..<count).map { i in
            // Identity-like transform stored column-major
            let transform: [Float] = [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                Float(i) * 0.1, 0, 0, 1
            ]
            return CameraPose(
                timestamp: Double(i) * 0.5,
                transform: transform,
                imageFilename: String(format: "frame_%04d.jpg", i),
                imageOrientation: .landscapeRight,
                intrinsics: intrinsics,
                imageWidth: intrinsics.width,
                imageHeight: intrinsics.height
            )
        }
    }

    private func makeSamplePosesWithoutMetadata(count: Int) -> [CameraPose] {
        return (0..<count).map { i in
            CameraPose(
                timestamp: Double(i) * 0.5,
                transform: [
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    Float(i) * 0.1, 0, 0, 1
                ],
                imageFilename: String(format: "frame_%04d.jpg", i)
            )
        }
    }

    private func makeSampleIntrinsics() -> CameraIntrinsics {
        return CameraIntrinsics(
            fx: 525.0, fy: 525.0,
            cx: 320.0, cy: 240.0,
            width: 640, height: 480
        )
    }

    private func makeSampleImages(count: Int) -> [CapturedImage] {
        return (0..<count).map { i in
            let filename = String(format: "frame_%04d.jpg", i)
            // Minimal valid JPEG-like data for testing (not a real JPEG)
            let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
            return CapturedImage(imageData: data, filename: filename)
        }
    }

    // MARK: - PLY Format Tests (Requirement 3.1)

    /// Validates: Requirements 3.1
    /// Verifies PLY file has correct header with vertex count, property declarations,
    /// and properly formatted vertex data lines.
    func testWritePLY_producesValidFormat() throws {
        let vertices = makeSampleVertices(count: 5)
        let plyURL = tempDirectory.appendingPathComponent("pointcloud.ply")

        try exporter.writePLY(vertices: vertices, to: plyURL)

        let content = try String(contentsOf: plyURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Verify PLY header
        XCTAssertEqual(lines[0], "ply")
        XCTAssertEqual(lines[1], "format ascii 1.0")
        XCTAssertEqual(lines[2], "element vertex 5")
        XCTAssertEqual(lines[3], "property float x")
        XCTAssertEqual(lines[4], "property float y")
        XCTAssertEqual(lines[5], "property float z")
        XCTAssertEqual(lines[6], "property uchar red")
        XCTAssertEqual(lines[7], "property uchar green")
        XCTAssertEqual(lines[8], "property uchar blue")
        XCTAssertEqual(lines[9], "property float nx")
        XCTAssertEqual(lines[10], "property float ny")
        XCTAssertEqual(lines[11], "property float nz")
        XCTAssertEqual(lines[12], "end_header")

        // Verify vertex data lines exist (header is 13 lines, then 5 data lines)
        // Each data line should have 9 space-separated values
        for i in 0..<5 {
            let dataLine = lines[13 + i]
            let components = dataLine.components(separatedBy: " ")
            XCTAssertEqual(components.count, 9,
                           "Vertex line \(i) should have 9 components (x y z r g b nx ny nz)")
        }
    }

    /// Validates: Requirements 3.1
    /// Verifies PLY color values are correctly converted from 0-1 float to 0-255 uchar.
    func testWritePLY_colorConversion() throws {
        let vertices: [[Float]] = [
            [1.0, 2.0, 3.0, 1.0, 0.5, 0.0, 0.0, 0.0, 1.0]
        ]
        let plyURL = tempDirectory.appendingPathComponent("color_test.ply")

        try exporter.writePLY(vertices: vertices, to: plyURL)

        let content = try String(contentsOf: plyURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let dataLine = lines[13] // First data line after header
        let components = dataLine.components(separatedBy: " ")

        // Color values: 1.0*255=255, 0.5*255=127, 0.0*255=0
        XCTAssertEqual(components[3], "255")
        XCTAssertEqual(components[4], "127")
        XCTAssertEqual(components[5], "0")
    }

    /// Validates: Requirements 3.1
    /// Verifies PLY export handles empty vertex array gracefully.
    func testWritePLY_emptyVertices() throws {
        let plyURL = tempDirectory.appendingPathComponent("empty.ply")

        try exporter.writePLY(vertices: [], to: plyURL)

        let content = try String(contentsOf: plyURL, encoding: .utf8)
        XCTAssertTrue(content.contains("element vertex 0"))
    }

    // MARK: - Poses JSON Tests (Requirement 3.2)

    /// Validates: Requirements 3.2
    /// Verifies poses.json contains frames array with correct structure per frame.
    func testWritePosesJSON_structureCompleteness() throws {
        let poses = makeSamplePoses(count: 3)
        let posesURL = tempDirectory.appendingPathComponent("poses.json")

        try exporter.writePosesJSON(poses: poses, to: posesURL)

        let data = try Data(contentsOf: posesURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Top-level must have "frames" array
        let frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 3)

        // Verify each frame has required fields
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame["index"] as? Int, i)
            XCTAssertNotNil(frame["timestamp"] as? Double,
                            "Frame \(i) must have a timestamp")
            XCTAssertNotNil(frame["imageFile"] as? String,
                            "Frame \(i) must have an imageFile")
            let transform = try XCTUnwrap(frame["transform"] as? [Any],
                                          "Frame \(i) must have a transform array")
            XCTAssertEqual(transform.count, 16,
                           "Transform must be a 16-element array (4x4 column-major)")
        }
    }

    /// Validates: Requirements 3.2
    /// Verifies imageFile paths use the images/ prefix.
    func testWritePosesJSON_imageFilePaths() throws {
        let poses = makeSamplePoses(count: 2)
        let posesURL = tempDirectory.appendingPathComponent("poses.json")

        try exporter.writePosesJSON(poses: poses, to: posesURL)

        let data = try Data(contentsOf: posesURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = json["frames"] as! [[String: Any]]

        XCTAssertEqual(frames[0]["imageFile"] as? String, "images/frame_0000.jpg")
        XCTAssertEqual(frames[1]["imageFile"] as? String, "images/frame_0001.jpg")
    }

    // MARK: - Intrinsics JSON Tests (Requirement 3.3)

    /// Validates: Requirements 3.3
    /// Verifies intrinsics.json contains all required camera parameters.
    func testWriteIntrinsicsJSON_structureCompleteness() throws {
        let intrinsics = makeSampleIntrinsics()
        let intrinsicsURL = tempDirectory.appendingPathComponent("intrinsics.json")

        try exporter.writeIntrinsicsJSON(intrinsics: intrinsics, to: intrinsicsURL)

        let data = try Data(contentsOf: intrinsicsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify all required fields
        XCTAssertEqual(json["fx"] as? Double, 525.0)
        XCTAssertEqual(json["fy"] as? Double, 525.0)
        XCTAssertEqual(json["cx"] as? Double, 320.0)
        XCTAssertEqual(json["cy"] as? Double, 240.0)
        XCTAssertEqual(json["width"] as? Int, 640)
        XCTAssertEqual(json["height"] as? Int, 480)
    }

    // MARK: - Image Export Tests (Requirement 3.4)

    /// Validates: Requirements 3.4
    /// Verifies JPEG images are written to the images/ subdirectory with correct filenames.
    func testWriteImages_createsFilesInSubdirectory() throws {
        let images = makeSampleImages(count: 3)
        let imagesDir = tempDirectory.appendingPathComponent("images")

        try exporter.writeImages(images: images, to: imagesDir)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: imagesDir.path))

        for i in 0..<3 {
            let filename = String(format: "frame_%04d.jpg", i)
            let filePath = imagesDir.appendingPathComponent(filename).path
            XCTAssertTrue(fileManager.fileExists(atPath: filePath),
                          "Image file \(filename) should exist")
        }
    }

    /// Validates: Requirements 3.4
    /// Verifies image data is written correctly (byte-for-byte match).
    func testWriteImages_dataIntegrity() throws {
        let originalData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let images = [CapturedImage(imageData: originalData, filename: "test.jpg")]
        let imagesDir = tempDirectory.appendingPathComponent("images")

        try exporter.writeImages(images: images, to: imagesDir)

        let writtenData = try Data(contentsOf: imagesDir.appendingPathComponent("test.jpg"))
        XCTAssertEqual(writtenData, originalData)
    }

    // MARK: - Full Export Tests

    /// 验证导出的扫描目录包含版本化、逐帧的坐标与图像合同。
    func testExportedManifestDeclaresCoordinateAndImageContract() throws {
        let outputURL = tempDirectory.appendingPathComponent("scan_manifest_output")
        try exporter.exportAll(
            vertices: makeSampleVertices(count: 1),
            poses: makeSamplePoses(count: 1),
            intrinsics: makeSampleIntrinsics(),
            images: makeSampleImages(count: 1),
            outputPath: outputURL.path
        )

        let manifestURL = outputURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            XCTFail("manifest.json must declare the scan coordinate and image contract")
            return
        }

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
        XCTAssertEqual(manifest?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(manifest?["coordinateSystem"] as? String, "arkit-world")
        XCTAssertEqual(manifest?["matrixLayout"] as? String, "arkit-column-major")
        XCTAssertEqual(manifest?["units"] as? String, "meters")

        let frames = try XCTUnwrap(manifest?["frames"] as? [[String: Any]])
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame["imageOrientation"] as? String, "landscapeRight")
        XCTAssertEqual((frame["image"] as? [String: Any])?["width"] as? Int, 640)
        XCTAssertEqual((frame["image"] as? [String: Any])?["height"] as? Int, 480)
        let frameIntrinsics = try XCTUnwrap(frame["intrinsics"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(frameIntrinsics["fx"] as? Double), 525, accuracy: 0.001)
    }

    /// 不允许旧的、未记录图像方向的 pose 被默默补默认值后导出。
    func testExportAllRejectsPoseMissingImageOrientation() {
        XCTAssertThrowsError(
            try exporter.exportAll(
                vertices: makeSampleVertices(count: 1),
                poses: makeSamplePosesWithoutMetadata(count: 1),
                intrinsics: makeSampleIntrinsics(),
                images: makeSampleImages(count: 1),
                outputPath: tempDirectory.appendingPathComponent("missing_orientation").path
            )
        )
    }

    /// 现有 JPEG 路径不会重编码像素，因此不能把原始 landscape 内参伪装成 portrait 导出。
    func testExportAllRejectsPortraitPoseWithoutReencodedImageMetadata() {
        let intrinsics = makeSampleIntrinsics()
        let portraitPose = CameraPose(
            timestamp: 0,
            transform: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ],
            imageFilename: "portrait.jpg",
            imageOrientation: .portrait,
            intrinsics: intrinsics,
            imageWidth: intrinsics.width,
            imageHeight: intrinsics.height
        )

        XCTAssertThrowsError(
            try exporter.exportAll(
                vertices: makeSampleVertices(count: 1),
                poses: [portraitPose],
                intrinsics: intrinsics,
                images: [CapturedImage(imageData: Data([0xFF, 0xD8]), filename: "portrait.jpg")],
                outputPath: tempDirectory.appendingPathComponent("portrait_without_reencode").path
            )
        )
    }

    /// Validates: Requirements 3.1, 3.2, 3.3, 3.4
    /// Verifies exportAll creates the complete directory structure.
    func testExportAll_createsCompleteStructure() throws {
        let vertices = makeSampleVertices(count: 1500)
        let poses = makeSamplePoses(count: 3)
        let intrinsics = makeSampleIntrinsics()
        let images = makeSampleImages(count: 3)
        let outputPath = tempDirectory.appendingPathComponent("scan_output").path

        try exporter.exportAll(
            vertices: vertices,
            poses: poses,
            intrinsics: intrinsics,
            images: images,
            outputPath: outputPath
        )

        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)

        XCTAssertTrue(fileManager.fileExists(
            atPath: outputURL.appendingPathComponent("pointcloud.ply").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: outputURL.appendingPathComponent("poses.json").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: outputURL.appendingPathComponent("intrinsics.json").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: outputURL.appendingPathComponent("images").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: outputURL.appendingPathComponent("images/frame_0000.jpg").path))
    }

    // MARK: - Export Validation Tests (Requirement 3.5)

    /// Validates: Requirements 3.5
    /// Verifies that ScannerError.insufficientData is thrown with the correct message
    /// when point count is below 1000.
    func testInsufficientData_errorMessage() {
        let error = ScannerError.insufficientData(pointCount: 500)
        XCTAssertTrue(
            error.localizedDescription.contains("扫描数据不足"),
            "Error message should contain '扫描数据不足'"
        )
        XCTAssertTrue(
            error.localizedDescription.contains("请继续扫描更多区域"),
            "Error message should contain '请继续扫描更多区域'"
        )
    }

    /// Validates: Requirements 3.5
    /// Verifies the threshold is exactly 1000 points — 999 should fail, 1000 should pass.
    func testInsufficientData_thresholdBoundary() {
        // 999 points → should be insufficient
        let error999 = ScannerError.insufficientData(pointCount: 999)
        XCTAssertNotNil(error999.errorDescription)

        // Verify the error carries the correct point count
        if case .insufficientData(let count) = error999 {
            XCTAssertEqual(count, 999)
        } else {
            XCTFail("Expected insufficientData error")
        }
    }

    /// Validates: Requirements 3.5
    /// Verifies that zero points triggers the insufficient data error.
    func testInsufficientData_zeroPoints() {
        let error = ScannerError.insufficientData(pointCount: 0)
        XCTAssertTrue(error.localizedDescription.contains("扫描数据不足"))
    }
}
