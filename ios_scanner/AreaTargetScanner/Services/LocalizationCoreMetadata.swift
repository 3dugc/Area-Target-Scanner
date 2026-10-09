import Foundation
import AreaTargetNative

enum LocalizationCoreMetadata {
    /// Raw replay identities do not use this live display-session metadata.
    static func liveBuildConfiguration(base: String?) -> String {
        appending(liveSessionProfile, to: base)
    }

    static func immersalLiveBuildConfiguration(base: String?) -> String {
        liveBuildConfiguration(base: immersalCalibrationBuildConfiguration(base: base))
    }

    /// Static map-to-scan calibration runs in live and raw-replay preparation.
    static func immersalCalibrationBuildConfiguration(base: String?) -> String {
        appending(calibrationProfile, to: base)
    }

    private static func appending(_ profile: String, to base: String?) -> String {
        ([base].compactMap { $0 }.filter { !$0.isEmpty } + [profile]).joined(separator: ";")
    }

    private static let liveSessionProfile: String = {
        var profile = ATCSessionConfigV2()
        profile.struct_size = UInt32(MemoryLayout<ATCSessionConfigV2>.size)
        profile.api_version = atc_get_api_version()
        let status = atc_get_default_session_config_v2(&profile)
        guard status == Int32(ATC_OK) else { return "display_core_profile_unavailable_status=\(status)" }
        return [
            "display_core_session_api=\(profile.api_version)",
            "display_core_window=\(profile.window_size)",
            "display_core_init=\(profile.initialization_samples)",
            "display_core_recovery=\(profile.recovery_samples)",
            "display_core_translation_m=\(profile.max_translation_residual_m)",
            "display_core_rotation_rad=\(profile.max_rotation_residual_rad)",
            "display_core_pose_skew_ns=\(profile.max_pose_skew_ns)",
            "display_core_alignment_age_ns=\(profile.max_alignment_age_ns)",
            "display_core_result_age_ns=\(profile.max_result_age_ns)",
            "display_core_tau_s=\(profile.smoothing_tau_seconds)"
        ].joined(separator: ";")
    }()

    private static let calibrationProfile: String = {
        var profile = ATCRigidConsensusConfigV2()
        profile.struct_size = UInt32(MemoryLayout<ATCRigidConsensusConfigV2>.size)
        profile.api_version = atc_get_api_version()
        let status = atc_get_default_rigid_consensus_config_v2(&profile)
        guard status == Int32(ATC_OK) else { return "calibration_core_profile_unavailable_status=\(status)" }
        return [
            "calibration_core_api=\(profile.api_version)",
            "calibration_core_minimum_inliers=\(profile.minimum_inliers)",
            "calibration_core_maximum_candidates=\(profile.maximum_candidates)",
            "calibration_core_inlier_ratio=\(profile.minimum_inlier_ratio)",
            "calibration_core_translation_m=\(profile.maximum_translation_m)",
            "calibration_core_rotation_rad=\(profile.maximum_rotation_rad)"
        ].joined(separator: ";")
    }()
}
