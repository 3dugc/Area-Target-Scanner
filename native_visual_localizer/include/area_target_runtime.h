/** Version 2 synchronous C ABI. See docs/contracts/area-target-runtime-v2.md.
 * All transforms use column vectors and row-major float[16] storage.
 * T_A_B maps B to A. Scan and world are right-handed, in metres.
 * The camera is optical: x right, y down, z forward. Legacy vl_* is separate.
 * Buffers are borrowed for the duration of the synchronous call only.
 * One serial owner per handle; do not race a call with reset/destroy.
 */
#ifndef AREA_TARGET_RUNTIME_H
#define AREA_TARGET_RUNTIME_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
# define ATC_API __declspec(dllexport)
#else
# define ATC_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
#define ATC_API_VERSION UINT32_C(2)
#define ATC_MAP_POLICY_VERSION UINT32_C(1)
#define ATC_GRAY_QUALITY_POLICY_VERSION UINT32_C(1)
#define ATC_KEYFRAME_SELECTION_POLICY_VERSION UINT32_C(1)
#define ATC_ASSET_SCHEMA_LEGACY_V1 UINT32_C(1)
typedef void* ATCHandle;
typedef void* ATCSessionHandle;
typedef int32_t ATCStatus;
enum {
    ATC_OK=0, ATC_NO_MATCH=1, ATC_INVALID_ARGUMENT=-1, ATC_ABI_MISMATCH=-2,
    ATC_MAP_NOT_LOADED=-3, ATC_MAP_INVALID=-4, ATC_RESOURCE_LIMIT=-5,
    ATC_INTERNAL_ERROR=-6, ATC_STALE_FRAME=-7, ATC_UNSUPPORTED_FORMAT=-8
};
enum { ATC_PIXEL_FORMAT_GRAY8=1 };
enum { ATC_MAP_COORDINATE_LEGACY_SCAN_RH_METERS=1 };
enum { ATC_TRACKING_QUALITY_UNAVAILABLE=0, ATC_TRACKING_QUALITY_LIMITED=1, ATC_TRACKING_QUALITY_NORMAL=2 };
enum { ATC_SESSION_INITIALIZING=0, ATC_SESSION_TRACKING=1, ATC_SESSION_LOST=2,
       ATC_SESSION_CANDIDATE=3, ATC_SESSION_DEGRADED=4 };
enum { ATC_MODE_NONE=0, ATC_MODE_RAW=1, ATC_MODE_ALIGNED=2, ATC_MODE_PROPAGATED=3 };
enum {
    ATC_REJECTION_NONE=0, ATC_REJECTION_NO_TRACKING=1, ATC_REJECTION_IDENTITY=2,
    ATC_REJECTION_CLOCK_MAPPING=3, ATC_REJECTION_TRACKING_INVALID=4,
    ATC_REJECTION_POSE_SKEW=5, ATC_REJECTION_OUTLIER=6,
    ATC_REJECTION_ALIGNMENT_AGE=7, ATC_REJECTION_STALE_FRAME=8,
    ATC_REJECTION_INVALID_RAW=9, ATC_REJECTION_RESULT_AGE=10,
    ATC_REJECTION_DELIVERY_CLOCK=11
};
enum {
    ATC_GRAY_QUALITY_ACCEPTED=0, ATC_GRAY_QUALITY_UNREADABLE=1,
    ATC_GRAY_QUALITY_TOO_DARK=2, ATC_GRAY_QUALITY_TOO_BRIGHT=3,
    ATC_GRAY_QUALITY_SATURATED=4, ATC_GRAY_QUALITY_LOW_TEXTURE=5,
    ATC_GRAY_QUALITY_BLURRED=6
};
typedef struct ATCConfigV2 {
    uint32_t struct_size, api_version;
    uint64_t max_image_bytes;
    uint32_t max_dimension, map_policy_version, map_coordinate_policy;
    uint32_t max_keyframes, max_vocabulary_words;
    uint32_t max_orb_features_per_keyframe, max_akaze_features_per_keyframe;
    uint64_t max_database_bytes, max_total_features, max_bow_products;
    uint64_t max_sql_steps, max_sql_time_ns;
} ATCConfigV2;
typedef struct ATCFrameV2 {
    uint32_t struct_size, api_version;
    uint64_t frame_id, capture_timestamp_ns, map_generation, capture_clock_epoch, camera_id;
    const uint8_t* data;
    uint64_t byte_length, row_stride;
    uint32_t width, height, pixel_format;
    float fx, fy, cx, cy;
} ATCFrameV2;
typedef struct ATCMapInfoV2 {
    uint32_t struct_size, api_version;
    uint64_t map_instance_id, keyframe_count, orb_feature_count, akaze_feature_count, vocabulary_word_count;
    uint32_t asset_schema_compatibility_id, map_coordinate_policy;
} ATCMapInfoV2;
typedef struct ATCResultV2 {
    uint32_t struct_size, api_version;
    ATCStatus status;
    uint32_t raw_pose_valid;
    uint64_t frame_id, capture_timestamp_ns, map_generation, capture_clock_epoch, camera_id, map_instance_id;
    float camera_from_scan[16];
    uint32_t inliers;
    float confidence, reprojection_rmse_px;
    uint32_t reprojection_error_valid;
} ATCResultV2;
/* The optional default profile is an engineering starting point, not a
 * device-independent accuracy guarantee. Counts are samples, distances metres,
 * rotation radians, ages/skew nanoseconds, smoothing time constant seconds. */
typedef struct ATCSessionConfigV2 {
    uint32_t struct_size, api_version;
    uint32_t window_size, initialization_samples, recovery_samples;
    float max_translation_residual_m, max_rotation_residual_rad;
    uint64_t max_pose_skew_ns, max_alignment_age_ns, max_result_age_ns;
    float smoothing_tau_seconds;
} ATCSessionConfigV2;
typedef struct ATCTrackingSampleV2 {
    uint32_t struct_size, api_version;
    uint64_t frame_id, capture_timestamp_ns, map_generation, capture_clock_epoch, camera_id;
    uint64_t pose_timestamp_ns, tracking_epoch;
    uint32_t clock_mapping_valid, pose_valid, extrinsics_valid, tracking_quality;
    float world_from_camera[16];
} ATCTrackingSampleV2;
typedef struct ATCSessionResultV2 {
    uint32_t struct_size, api_version;
    ATCStatus status;
    uint32_t raw_pose_valid, alignment_valid, propagated_pose_valid;
    uint32_t state, mode, rejection_reason;
    uint64_t frame_id, capture_timestamp_ns, map_generation, capture_clock_epoch, camera_id;
    uint64_t map_instance_id, tracking_epoch, alignment_age_ns;
    float camera_from_scan[16], world_from_scan[16];
} ATCSessionResultV2;
/* Shared deterministic quality policy. The saturated fraction is the larger
 * single-endpoint fraction (<=4 or >=251), so a black/white texture is not
 * mistaken for a uniformly clipped exposure. No image or feature mutation. */
typedef struct ATCGrayQualityV2 {
    uint32_t struct_size, api_version, policy_version, accepted, rejection_reason;
    float laplacian_variance, gray_standard_deviation, mean_intensity, saturated_fraction;
    uint64_t sample_count;
} ATCGrayQualityV2;
enum { ATC_CONSENSUS_ACCEPTED=0, ATC_CONSENSUS_INSUFFICIENT=1,
       ATC_CONSENSUS_INVALID_TRANSFORM=2, ATC_CONSENSUS_INCONSISTENT=3 };
/* Static Immersal mesh calibration preserves an actual measured medoid;
 * minimum ratio, distances in metres and rotation in radians are core policy. */
typedef struct ATCRigidConsensusConfigV2 {
    uint32_t struct_size, api_version, minimum_inliers, maximum_candidates;
    float minimum_inlier_ratio, maximum_translation_m, maximum_rotation_rad;
    uint32_t reserved;
} ATCRigidConsensusConfigV2;
typedef struct ATCRigidConsensusResultV2 {
    uint32_t struct_size, api_version, valid, rejection_reason;
    uint32_t matched_count, inlier_count, selected_index;
    float maximum_translation_residual_m, maximum_rotation_residual_rad;
    float map_from_scan[16];
} ATCRigidConsensusResultV2;
/* Fixed-size array elements. source_ordinal refers to the original input list;
 * pose_valid is a hint: malformed proper-rigid poses use temporal coverage.
 * accepted and Laplacian variance originate from the shared quality assess. */
typedef struct ATCKeyframeCandidateV2 {
    uint32_t struct_size, api_version, source_ordinal, pose_valid;
    float laplacian_variance;
    uint32_t quality_accepted;
    float camera_to_world[16];
} ATCKeyframeCandidateV2;
/* Frozen map resource policy v1. Callers can choose smaller positive limits.
 * Unknown coordinate policies are rejected; no schema-coordinate guessing. */
static inline ATCConfigV2 atc_default_config_v2(void) {
    ATCConfigV2 c = {0};
    c.struct_size=(uint32_t)sizeof(c); c.api_version=ATC_API_VERSION;
    c.max_image_bytes=UINT64_C(64)*1024*1024; c.max_dimension=8192;
    c.map_policy_version=ATC_MAP_POLICY_VERSION;
    c.map_coordinate_policy=ATC_MAP_COORDINATE_LEGACY_SCAN_RH_METERS;
    c.max_keyframes=1000; c.max_vocabulary_words=4096;
    c.max_orb_features_per_keyframe=2000; c.max_akaze_features_per_keyframe=8192;
    c.max_database_bytes=UINT64_C(512)*1024*1024; c.max_total_features=200000;
    c.max_bow_products=200000000; c.max_sql_steps=20000000;
    c.max_sql_time_ns=UINT64_C(3000000000);
    return c;
}
ATC_API uint32_t atc_get_api_version(void);
ATC_API ATCStatus atc_create(const ATCConfigV2* config, ATCHandle* out_handle);
ATC_API ATCStatus atc_load_map(ATCHandle handle, const char* bundle_directory, ATCMapInfoV2* out_info);
ATC_API ATCStatus atc_localize(ATCHandle handle, const ATCFrameV2* frame, ATCResultV2* out_result);
ATC_API ATCStatus atc_reset(ATCHandle handle);
ATC_API void atc_destroy(ATCHandle* handle);
ATC_API ATCStatus atc_session_create(const ATCSessionConfigV2* config, ATCSessionHandle* out_handle);
ATC_API ATCStatus atc_get_default_session_config_v2(ATCSessionConfigV2* out_config);
ATC_API ATCStatus atc_session_update(ATCSessionHandle handle, const ATCResultV2* raw, const ATCTrackingSampleV2* tracking, ATCSessionResultV2* out_result);
/* now_timestamp_ns uses the same mapped monotonic clock/epoch as exposure.
 * The legacy update uses exposure as now; new bridges must use update_at. */
ATC_API ATCStatus atc_session_update_at(ATCSessionHandle handle, const ATCResultV2* raw, const ATCTrackingSampleV2* tracking, uint64_t now_timestamp_ns, ATCSessionResultV2* out_result);
/* Poll never advances a visual frame ID or exposure, nor produces raw success.
 * The bridge resets on unavailable tracking, map/clock/tracking-epoch changes. */
ATC_API ATCStatus atc_session_poll(ATCSessionHandle handle, uint64_t now_timestamp_ns, ATCSessionResultV2* out_result);
ATC_API ATCStatus atc_session_reset(ATCSessionHandle handle, uint64_t map_generation, uint64_t tracking_epoch);
ATC_API void atc_session_destroy(ATCSessionHandle* handle);
/* Only the GRAY8 buffer shape/stride is assessed; frame identity and K are
 * irrelevant to quality and may be zero. Caller prepares the output ABI head. */
ATC_API ATCStatus atc_assess_gray_quality(const ATCFrameV2* frame, ATCGrayQualityV2* out_quality);
/* Candidate-only trigger: at least .2s, then .5s or .10m or 15 degrees.
 * Poses are row-major proper rigid camera-to-world in metres. Null previous
 * pose denotes first capture/reset; timestamps use the same monotonic clock.
 * Invalid transform, null output or backwards time returns INVALID_ARGUMENT. */
ATC_API ATCStatus atc_capture_candidate_v2(uint64_t current_timestamp_ns, uint64_t previous_capture_timestamp_ns, const float* previous_camera_to_world, const float* camera_to_world, uint32_t* out_should_capture);
ATC_API ATCStatus atc_get_default_rigid_consensus_config_v2(ATCRigidConsensusConfigV2* out_config);
/* Converts SDK optical-camera quaternion (xyzw) once to AR-camera basis,
 * then composes mapFromARCamera * inverse(scanFromARCamera). No world flip. */
ATC_API ATCStatus atc_make_immersal_alignment_candidate_v2(const float* scan_from_ar_camera, const float* map_position_xyz, const float* map_rotation_xyzw, float* out_map_from_scan);
/* candidates is a contiguous array of count row-major float[16] matrices. */
ATC_API ATCStatus atc_estimate_rigid_consensus_v2(const ATCRigidConsensusConfigV2* config, const float* candidates, uint32_t count, ATCRigidConsensusResultV2* out_result);
/* Deterministic O(N*K) coverage, max N=10000, positive budget K<=80; zero
 * budget keeps all accepted candidates. Output is original ordinals sorted
 * ascending; capacity must cover min(accepted_count,budget), or all for zero.
 * Input ordinal values must be unique and < total_source_count. */
ATC_API ATCStatus atc_select_keyframes_v2(const ATCKeyframeCandidateV2* candidates, uint32_t candidate_count, uint32_t total_source_count, uint32_t max_keyframes, uint32_t* out_ordinals, uint32_t output_capacity, uint32_t* out_selected_count);
#ifdef __cplusplus
}
#endif
#endif
