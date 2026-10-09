import XCTest
import AreaTargetNative
@testable import AreaTargetScanner

final class LocalizationCoreMetadataTests: XCTestCase {
    func testLiveIdentityKeepsCallerConfigurationAndRecordsActualCoreProfile() {
        var profile = ATCSessionConfigV2()
        profile.struct_size = UInt32(MemoryLayout<ATCSessionConfigV2>.size)
        profile.api_version = atc_get_api_version()
        XCTAssertEqual(atc_get_default_session_config_v2(&profile), Int32(ATC_OK))
        let identity = LocalizationCoreMetadata.liveBuildConfiguration(base: "profile=fast;uv_unwrap=1")
        XCTAssertTrue(identity.hasPrefix("profile=fast;uv_unwrap=1;"))
        XCTAssertTrue(identity.contains("display_core_session_api=\(profile.api_version)"))
        XCTAssertTrue(identity.contains("display_core_window=\(profile.window_size)"))
        XCTAssertTrue(identity.contains("display_core_init=\(profile.initialization_samples)"))
        XCTAssertTrue(identity.contains("display_core_recovery=\(profile.recovery_samples)"))
        XCTAssertTrue(identity.contains("display_core_translation_m=\(profile.max_translation_residual_m)"))
        XCTAssertTrue(identity.contains("display_core_rotation_rad=\(profile.max_rotation_residual_rad)"))
        XCTAssertTrue(identity.contains("display_core_alignment_age_ns=\(profile.max_alignment_age_ns)"))
        XCTAssertTrue(identity.contains("display_core_result_age_ns=\(profile.max_result_age_ns)"))
        XCTAssertTrue(identity.contains("display_core_tau_s=\(profile.smoothing_tau_seconds)"))
    }

    func testLiveIdentityWithoutCallerMetadataStillRecordsProfileDeterministically() {
        let first = LocalizationCoreMetadata.liveBuildConfiguration(base: nil)
        XCTAssertTrue(first.hasPrefix("display_core_session_api="))
        XCTAssertEqual(first, LocalizationCoreMetadata.liveBuildConfiguration(base: nil))
        XCTAssertEqual(first, LocalizationCoreMetadata.liveBuildConfiguration(base: ""))
    }

    func testImmersalCalibrationIdentityRecordsCoreDefaultsWithoutClaimingDisplayFiltering() {
        var profile = ATCRigidConsensusConfigV2()
        profile.struct_size = UInt32(MemoryLayout<ATCRigidConsensusConfigV2>.size)
        profile.api_version = atc_get_api_version()
        XCTAssertEqual(atc_get_default_rigid_consensus_config_v2(&profile), Int32(ATC_OK))
        let base = "cloud-default;frames=32;continuous-replay;no-ar-prior"
        let identity = LocalizationCoreMetadata.immersalCalibrationBuildConfiguration(base: base)
        XCTAssertTrue(identity.hasPrefix(base + ";"))
        XCTAssertTrue(identity.contains("calibration_core_api=\(profile.api_version)"))
        XCTAssertTrue(identity.contains("calibration_core_minimum_inliers=\(profile.minimum_inliers)"))
        XCTAssertTrue(identity.contains("calibration_core_maximum_candidates=\(profile.maximum_candidates)"))
        XCTAssertTrue(identity.contains("calibration_core_inlier_ratio=\(profile.minimum_inlier_ratio)"))
        XCTAssertTrue(identity.contains("calibration_core_translation_m=\(profile.maximum_translation_m)"))
        XCTAssertTrue(identity.contains("calibration_core_rotation_rad=\(profile.maximum_rotation_rad)"))
        XCTAssertFalse(identity.contains("display_core_session_api="))
        let live = LocalizationCoreMetadata.immersalLiveBuildConfiguration(base: base)
        XCTAssertTrue(live.hasPrefix(identity + ";"))
        XCTAssertTrue(live.contains("display_core_session_api="))
    }
}
