import XCTest
import simd
@testable import AreaTargetScanner

final class ScanCaptureQualityTests: XCTestCase {
    func testRejectsExposureFlatTextureAndBlur() {
        for value: UInt8 in [0, 255] {
            XCTAssertEqual(ScanFrameQuality.assess(width: 160, height: 120) { _, _ in value }.rejection, .exposure)
        }
        XCTAssertEqual(ScanFrameQuality.assess(width: 160, height: 120) { _, _ in 128 }.rejection, .texture)
        XCTAssertEqual(ScanFrameQuality.assess(width: 160, height: 120) { x, _ in UInt8(x + 40) }.rejection, .blur)
    }

    func testAcceptsTextureAndUsesBoundedSamples() {
        let result = ScanFrameQuality.assess(width: 1920, height: 1440) { x, y in
            return UInt8((x * 37 + y * 11) % 160 + 48)
        }
        XCTAssertNil(result.rejection)
        XCTAssertGreaterThan(result.sharpness, 8)
        XCTAssertLessThanOrEqual(result.sampleCount, 160 * 160)
    }

    func testRotationAddsAViewWithoutAllowingOverdenseFrames() {
        var policy = ScanKeyframePolicy()
        let first = matrix_identity_float4x4
        policy.recordCapture(at: 1, transform: first)
        let rotated = simd_float4x4(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        XCTAssertFalse(policy.shouldCapture(at: 1.1, transform: rotated))
        XCTAssertTrue(policy.shouldCapture(at: 1.25, transform: rotated))
        XCTAssertFalse(policy.shouldCapture(at: 1.25, transform: first))
        XCTAssertTrue(policy.shouldCapture(at: 1.5, transform: first))
    }

    func testResetAndFailedQualityDoNotAdvanceCapturedPose() {
        var policy = ScanKeyframePolicy()
        policy.recordCapture(at: 1, transform: matrix_identity_float4x4)
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 0.5
        XCTAssertFalse(policy.shouldCapture(at: 1.1, transform: moved))
        XCTAssertTrue(policy.shouldCapture(at: 1.3, transform: moved))
        // Rejection never calls recordCapture, so the same candidate can be retried.
        XCTAssertTrue(policy.shouldCapture(at: 1.4, transform: moved))
        policy.reset()
        XCTAssertTrue(policy.shouldCapture(at: 0, transform: matrix_identity_float4x4))
    }
}
