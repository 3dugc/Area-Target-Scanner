import XCTest
import simd
@testable import AreaTargetScanner

final class LocalizationAlignmentPolicyTests: XCTestCase {
    func testTwoConsistentFreshResultsConfirmAndSmallUpdatesStayRigid() throws {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(), sequence: 0, captureTime: 10, now: 10.1)
        XCTAssertEqual(policy.state, .candidate)
        XCTAssertNil(policy.alignment)
        policy.observe(worldFromMap: pose(x: 0.1, degrees: 2), sequence: 1, captureTime: 11.5, now: 11.6)
        XCTAssertEqual(policy.state, .confirmed)
        let confirmed = try XCTUnwrap(policy.alignment)
        XCTAssertEqual(confirmed.columns.3.x, 0.1, accuracy: 1e-6)
        policy.observe(worldFromMap: pose(x: 0.2, degrees: 4), sequence: 2, captureTime: 13, now: 13.1)
        let smoothed = try XCTUnwrap(policy.alignment)
        XCTAssertGreaterThanOrEqual(smoothed.columns.3.x, confirmed.columns.3.x)
        XCTAssertLessThan(smoothed.columns.3.x, 0.2)
        XCTAssertGreaterThanOrEqual(angleDegrees(smoothed), 1.99)
        XCTAssertLessThan(angleDegrees(smoothed), 4)
        XCTAssertTrue(LocalizationQueryFrame.rigid(smoothed))
    }

    func testSharedCoreSmoothingUsesElapsedTimeInsteadOfAPlatformFrameWeight() throws {
        let earlier = confirmedPolicy()
        let later = confirmedPolicy()
        for policy in [earlier, later] {
            policy.observe(worldFromMap: pose(x: 0.2), sequence: 2, captureTime: 13, now: 13)
        }
        earlier.observe(worldFromMap: pose(x: 0.2), sequence: 3, captureTime: 14.5, now: 14.5)
        later.observe(worldFromMap: pose(x: 0.2), sequence: 3, captureTime: 15.5, now: 15.5)
        let first = try XCTUnwrap(earlier.alignment)
        let second = try XCTUnwrap(later.alignment)
        XCTAssertGreaterThan(second.columns.3.x, first.columns.3.x)
        XCTAssertLessThan(second.columns.3.x, 0.2)
        XCTAssertTrue(LocalizationQueryFrame.rigid(first))
        XCTAssertTrue(LocalizationQueryFrame.rigid(second))
    }

    func testQuaternionWrapUsesShortestRotationPath() throws {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(degrees: 179), sequence: 0, captureTime: 10, now: 10)
        policy.observe(worldFromMap: pose(degrees: -179), sequence: 1, captureTime: 11.5, now: 11.5)
        policy.observe(worldFromMap: pose(degrees: 179), sequence: 2, captureTime: 13, now: 13)
        let actual = try XCTUnwrap(policy.alignment)
        XCTAssertGreaterThan(angleDegrees(actual), 178.9, "A shortest-path update must remain close to 180 degrees")
        XCTAssertTrue(LocalizationQueryFrame.rigid(actual))
    }

    func testFailureBreaksCandidateConfirmation() {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(), sequence: 0, captureTime: 10, now: 10)
        policy.observe(worldFromMap: nil, sequence: 1, captureTime: 11.5, now: 11.5)
        policy.observe(worldFromMap: pose(), sequence: 2, captureTime: 13, now: 13)
        XCTAssertEqual(policy.state, .candidate)
        XCTAssertNil(policy.alignment)
    }

    func testLargeTranslationAndRotationDoNotReplaceConfirmedPoseUntilReconfirmed() throws {
        for unexpected in [pose(x: 3), pose(degrees: 40)] {
            let policy = confirmedPolicy()
            let original = try XCTUnwrap(policy.alignment)
            policy.observe(worldFromMap: unexpected, sequence: 2, captureTime: 13, now: 13)
            XCTAssertEqual(policy.state, .degraded)
            XCTAssertEqual(policy.alignment, original)
            policy.observe(worldFromMap: unexpected, sequence: 3, captureTime: 14.5, now: 14.5)
            XCTAssertEqual(policy.state, .confirmed)
            XCTAssertEqual(policy.alignment, unexpected, "Reconfirmed distant poses must not blend across an unrelated map position")
        }
    }

    func testUnconfirmedCandidatesCannotExtendOldAlignmentDeadline() {
        let policy = confirmedPolicy()
        policy.observe(worldFromMap: pose(x: 5), sequence: 2, captureTime: 13, now: 13)
        policy.observe(worldFromMap: pose(x: -5), sequence: 3, captureTime: 14.5, now: 14.5)
        policy.tick(now: 14.5001)
        XCTAssertNil(policy.alignment)
        XCTAssertEqual(policy.state, .candidate)
    }

    func testFailureHoldsOnlyUntilLastAcceptedExposureDeadlineAndTickExpiresWhileBusy() {
        let policy = confirmedPolicy()
        policy.observe(worldFromMap: nil, sequence: 2, captureTime: 13, now: 13)
        XCTAssertEqual(policy.state, .degraded)
        XCTAssertNotNil(policy.alignment)
        policy.tick(now: 14.5)
        XCTAssertNotNil(policy.alignment)
        policy.tick(now: 14.5001)
        XCTAssertEqual(policy.state, .lost)
        XCTAssertNil(policy.alignment)
    }

    func testResultArrivalDoesNotRestartExposureBasedHoldDeadline() {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(), sequence: 0, captureTime: 10, now: 10.1)
        policy.observe(worldFromMap: pose(), sequence: 1, captureTime: 11.5, now: 12.9)
        XCTAssertEqual(policy.state, .confirmed)
        policy.tick(now: 14.5001)
        XCTAssertNil(policy.alignment)
    }

    func testStaleFutureAndNonRigidResultsNeverConfirm() {
        var invalid = pose(); invalid.columns.0.x = 2
        for value in [(pose(), 10.0, 13.001), (pose(), 10.0, 9.9), (invalid, 10.0, 10.0)] {
            let policy = LocalizationAlignmentPolicy()
            XCTAssertFalse(policy.observe(worldFromMap: value.0, sequence: 0, captureTime: value.1, now: value.2))
            policy.observe(worldFromMap: pose(), sequence: 1, captureTime: 14, now: 14)
            XCTAssertEqual(policy.state, .candidate)
            XCTAssertNil(policy.alignment)
        }
    }

    func testDuplicateSequenceAndReversedExposureCannotRefreshAcceptedPose() throws {
        let policy = confirmedPolicy()
        let original = try XCTUnwrap(policy.alignment)
        XCTAssertFalse(policy.observe(worldFromMap: pose(x: 0.2), sequence: 1, captureTime: 12, now: 12))
        XCTAssertFalse(policy.observe(worldFromMap: pose(x: 0.2), sequence: 2, captureTime: 11, now: 12.1))
        XCTAssertEqual(policy.alignment, original)
        policy.tick(now: 14.5001)
        XCTAssertNil(policy.alignment)
    }

    func testCandidateExpiresBeforeASeparatedNewObservationCanConfirmIt() {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(), sequence: 0, captureTime: 10, now: 10)
        policy.observe(worldFromMap: pose(), sequence: 1, captureTime: 14, now: 14)
        XCTAssertEqual(policy.state, .candidate)
        XCTAssertNil(policy.alignment)
    }

    func testResetClearsMapEpochOrderingConfirmationAndOldPose() {
        let policy = confirmedPolicy()
        policy.reset()
        XCTAssertEqual(policy.state, .searching)
        XCTAssertNil(policy.alignment)
        policy.observe(worldFromMap: pose(x: 100), sequence: 0, captureTime: 1, now: 1)
        XCTAssertEqual(policy.state, .candidate)
        XCTAssertNil(policy.alignment)
        policy.observe(worldFromMap: pose(x: 100), sequence: 1, captureTime: 2.5, now: 2.5)
        XCTAssertEqual(policy.state, .confirmed)
        XCTAssertEqual(policy.alignment?.columns.3.x, 100)
    }

    func testInvalidClockCannotLeaveAnIndefinitePoseVisible() {
        for now in [Double.nan, Double.infinity, 9.0] {
            let policy = confirmedPolicy()
            policy.tick(now: now)
            XCTAssertNil(policy.alignment)
        }
    }

    private func confirmedPolicy() -> LocalizationAlignmentPolicy {
        let policy = LocalizationAlignmentPolicy()
        policy.observe(worldFromMap: pose(), sequence: 0, captureTime: 10, now: 10)
        policy.observe(worldFromMap: pose(), sequence: 1, captureTime: 11.5, now: 11.5)
        return policy
    }

    private func pose(x: Float = 0, degrees: Float = 0) -> simd_float4x4 {
        var value = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        value.columns.3 = SIMD4(x, 0, 0, 1)
        return value
    }

    private func angleDegrees(_ pose: simd_float4x4) -> Float {
        let rotation = simd_quatf(simd_float3x3(columns: (
            SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))))
        return 2 * acos(min(1, abs(rotation.real))) * 180 / .pi
    }
}
