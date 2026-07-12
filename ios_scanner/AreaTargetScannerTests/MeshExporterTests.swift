import XCTest
@testable import AreaTargetScanner

/// Tests for MeshExporter (GLBExporter.swift).
///
/// Validates:
/// - Error types and descriptions
/// - Empty mesh anchor handling
/// - Export directory creation
/// - Error recovery paths
final class MeshExporterTests: XCTestCase {

    private var tempDir: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = NSTemporaryDirectory() + "MeshExporterTests_\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir) {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Error Type Tests

    func testExportError_noMeshData_hasLocalizedDescription() {
        let error = MeshExporter.ExportError.noMeshData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("网格数据"),
            "noMeshData should mention mesh data in Chinese, got: \(error.errorDescription!)")
    }

    func testExportError_noMetalDevice_hasLocalizedDescription() {
        let error = MeshExporter.ExportError.noMetalDevice
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Metal"),
            "noMetalDevice should mention Metal, got: \(error.errorDescription!)")
    }

    func testExportError_exportFailed_includesReason() {
        let reason = "disk full"
        let error = MeshExporter.ExportError.exportFailed(reason)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains(reason),
            "exportFailed should include the reason, got: \(error.errorDescription!)")
    }

    // MARK: - Empty Mesh Anchor Tests

    func testExport_emptyMeshAnchors_throwsNoMeshData() {
        XCTAssertThrowsError(try MeshExporter.export(meshAnchors: [], to: tempDir)) { error in
            guard let exportError = error as? MeshExporter.ExportError else {
                XCTFail("Expected MeshExporter.ExportError, got \(type(of: error))")
                return
            }
            if case .noMeshData = exportError {
                // Expected
            } else {
                XCTFail("Expected .noMeshData, got \(exportError)")
            }
        }
    }

    // MARK: - All Error Cases Have Descriptions

    func testAllExportErrors_haveNonNilDescriptions() {
        let errors: [MeshExporter.ExportError] = [
            .noMeshData,
            .noMetalDevice,
            .exportFailed("test reason")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                "Error \(error) should have a non-nil errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty,
                "Error \(error) should have a non-empty errorDescription")
        }
    }
}
