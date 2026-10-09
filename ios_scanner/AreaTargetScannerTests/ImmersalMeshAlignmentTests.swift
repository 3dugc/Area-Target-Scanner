import XCTest
import simd
@testable import AreaTargetScanner

final class ImmersalMeshAlignmentTests: XCTestCase {
    func testCandidateConvertsCVCameraBasisWithoutFlippingMapTranslation() throws {
        let candidate = try XCTUnwrap(ImmersalMeshAlignment.candidate(
            scanFromCamera: matrix_identity_float4x4, mapPosition: SIMD3(1, 2, 3),
            mapRotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))))
        var expected = matrix_identity_float4x4
        expected.columns.1.y = -1
        expected.columns.2.z = -1
        expected.columns.3 = SIMD4(1, 2, 3, 1)
        assertMatrix(candidate, equals: expected)
    }

    func testCandidateRecoversNonidentityMapFromScanAtDifferentCameraPoses() throws {
        let mapFromScan = pose(position: SIMD3(4, -2, 7), degrees: 43, axis: SIMD3(1, 2, 3))
        let cameras = [pose(position: SIMD3(1, 3, -4), degrees: -30),
                       pose(position: SIMD3(-2, 1, 6), degrees: 71, axis: SIMD3(1, 0, 0))]
        var cvFromAR = matrix_identity_float4x4
        cvFromAR.columns.1.y = -1; cvFromAR.columns.2.z = -1
        for scanFromCamera in cameras {
            let mapFromCVCamera = mapFromScan * scanFromCamera * cvFromAR
            let result = try XCTUnwrap(ImmersalMeshAlignment.candidate(
                scanFromCamera: scanFromCamera,
                mapPosition: SIMD3(mapFromCVCamera.columns.3.x, mapFromCVCamera.columns.3.y, mapFromCVCamera.columns.3.z),
                mapRotation: quaternion(mapFromCVCamera)))
            assertMatrix(result, equals: mapFromScan)
        }
    }

    func testCandidateRejectsInvalidScanPoseAndNativeQuaternion() {
        for invalid in invalidMatrices() {
            XCTAssertNil(ImmersalMeshAlignment.candidate(scanFromCamera: invalid,
                mapPosition: .zero, mapRotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))))
        }
        XCTAssertNil(ImmersalMeshAlignment.candidate(scanFromCamera: matrix_identity_float4x4,
            mapPosition: SIMD3(.nan, 0, 0), mapRotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))))
        for rotation in [simd_quatf(vector: .zero), simd_quatf(vector: SIMD4(.nan, 0, 0, 1))] {
            XCTAssertNil(ImmersalMeshAlignment.candidate(scanFromCamera: matrix_identity_float4x4,
                mapPosition: .zero, mapRotation: rotation))
        }
    }

    func testThreeConsistentPosesUseMeasuredRigidTransformAndResiduals() throws {
        let center = pose(position: SIMD3(2, -1, 4), degrees: 35)
        let left = pose(position: SIMD3(1.95, -1, 4), degrees: 34)
        let right = pose(position: SIMD3(2.1, -1, 4), degrees: 37)
        let result = try ImmersalMeshAlignment.estimate([left, center, right])
        assertMatrix(result.mapFromScan, equals: center)
        XCTAssertEqual(result.matchedCount, 3)
        XCTAssertEqual(result.inlierCount, 3)
        XCTAssertEqual(result.maxPositionResidualMeters, 0.1, accuracy: 0.00001)
        XCTAssertEqual(result.maxAngleResidualDegrees, 2, accuracy: 0.001)
    }

    func testSixtyPercentConsensusRejectsTranslationAndRotationOutliers() throws {
        let center = pose(position: SIMD3(1, 2, 3), degrees: 20)
        let candidates = [center,
                          pose(position: SIMD3(1.04, 2, 3), degrees: 21),
                          pose(position: SIMD3(0.98, 2, 3), degrees: 19),
                          pose(position: SIMD3(20, 2, 3), degrees: 20),
                          pose(position: SIMD3(1, 2, 3), degrees: 50)]
        let result = try ImmersalMeshAlignment.estimate(candidates)
        XCTAssertEqual(result.matchedCount, 5)
        XCTAssertEqual(result.inlierCount, 3)
        assertMatrix(result.mapFromScan, equals: center)
        XCTAssertLessThan(result.maxPositionResidualMeters, 0.05)
        XCTAssertLessThan(result.maxAngleResidualDegrees, 1.01)
    }

    func testTwoMatchesCannotEstablishAlignment() {
        for count in 0...2 {
            XCTAssertThrowsError(try ImmersalMeshAlignment.estimate(Array(repeating: matrix_identity_float4x4, count: count)))
        }
    }

    func testEquallySupportedDisjointClustersAreRejected() {
        let first = pose(position: .zero, degrees: 0)
        let second = pose(position: SIMD3(2, 0, 0), degrees: 30)
        XCTAssertThrowsError(try ImmersalMeshAlignment.estimate([first, first, first, second, second, second]))
    }

    func testThreeInliersBelowSixtyPercentAreRejected() {
        XCTAssertThrowsError(try ImmersalMeshAlignment.estimate([
            pose(), pose(), pose(), pose(position: SIMD3(2, 0, 0)),
            pose(position: SIMD3(4, 0, 0)), pose(position: SIMD3(6, 0, 0))]))
    }

    func testEstimateRejectsNonfiniteScaleShearReflectionAndProjectiveInputs() {
        for invalid in invalidMatrices() {
            XCTAssertThrowsError(try ImmersalMeshAlignment.estimate([pose(), pose(), pose(), invalid]))
        }
    }

    func testRotationResidualUsesShortArcAcross180Degrees() throws {
        let result = try ImmersalMeshAlignment.estimate([
            pose(degrees: 179), pose(degrees: -179), pose(degrees: 180)])
        XCTAssertEqual(result.inlierCount, 3)
        XCTAssertEqual(result.maxAngleResidualDegrees, 1, accuracy: 0.001)
    }

    func testDisagreementBeyondPositionOrAngleThresholdIsRejected() {
        XCTAssertThrowsError(try ImmersalMeshAlignment.estimate([
            pose(), pose(position: SIMD3(0.3, 0, 0)), pose(position: SIMD3(0.6, 0, 0))]))
        XCTAssertThrowsError(try ImmersalMeshAlignment.estimate([
            pose(degrees: 0), pose(degrees: 6), pose(degrees: 12)]))
    }

    private func invalidMatrices() -> [simd_float4x4] {
        var nonfinite = pose(); nonfinite.columns.3.x = .nan
        var zeroAxis = pose(); zeroAxis.columns.0 = .zero
        var scale = pose(); scale.columns.0.x = 2
        var shear = pose(); shear.columns.1.x = 0.2
        var reflection = pose(); reflection.columns.0.x = -1
        var projective = pose(); projective.columns.0.w = 0.1
        return [nonfinite, zeroAxis, scale, shear, reflection, projective]
    }

    private func pose(position: SIMD3<Float> = .zero, degrees: Float = 0,
                      axis: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        var result = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis)))
        result.columns.3 = SIMD4(position, 1)
        return result
    }

    private func quaternion(_ matrix: simd_float4x4) -> simd_quatf {
        simd_quatf(simd_float3x3(columns: (
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))))
    }

    private func assertMatrix(_ actual: simd_float4x4, equals expected: simd_float4x4,
                              file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 { for row in 0..<4 {
            XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 0.00001, file: file, line: line)
        } }
    }
}
