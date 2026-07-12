/**
 * visual_localizer.h - C API for Visual Localizer native plugin
 *
 * Provides ORB feature extraction, BoW keyframe retrieval, feature matching,
 * and PnP RANSAC localization via an opaque handle interface.
 * Designed for P/Invoke from Unity C#.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define VL_API __declspec(dllexport)
#else
  #define VL_API __attribute__((visibility("default")))
#endif

typedef void* VLHandle;

typedef struct {
    int state;           /* 0=INITIALIZING, 1=TRACKING, 2=LOST */
    float pose[16];      /* 4x4 row-major transform matrix */
    float confidence;    /* [0,1] */
    int matched_features;
} VLResult;

/* Debug diagnostics for pipeline troubleshooting */
typedef struct {
    int orb_keypoints;       /* ORB keypoints detected in current frame */
    int candidate_keyframes; /* Number of candidate keyframes selected */
    int best_kf_id;          /* ID of best matching keyframe (-1 if none) */
    int best_raw_matches;    /* Raw KNN matches before Lowe ratio filter */
    int best_good_matches;   /* Good matches after Lowe ratio filter */
    int best_inliers;        /* PnP RANSAC inlier count */
    float best_bow_sim;      /* Best BoW similarity score */
    float best_inlier_ratio; /* Best inlier ratio (inliers/good_matches) */
    /* --- 新增字段（末尾追加，保持 ABI 向后兼容）--- */
    int akaze_triggered;     /* AKAZE fallback 是否触发 (0/1) */
    int akaze_keypoints;     /* AKAZE 特征点数（未触发时为 0）*/
    int akaze_best_inliers;  /* AKAZE 最佳 inlier 数（未触发时为 0）*/
    int consistency_rejected; /* 当前帧是否被一致性过滤拒绝 (0/1) */
} VLDebugInfo;

/* Lifecycle */
VL_API VLHandle vl_create(void);
VL_API void     vl_destroy(VLHandle handle);

/* Data loading (called from C# after SQLite read) */
VL_API int  vl_add_vocabulary_word(VLHandle handle, int word_id,
                                    const unsigned char* descriptor, int desc_len,
                                    float idf_weight);
VL_API int  vl_add_keyframe(VLHandle handle, int kf_id,
                             const float* pose_4x4,
                             const unsigned char* descriptors, int desc_count,
                             const float* points3d, const float* points2d);
VL_API int  vl_add_keyframe_akaze(VLHandle handle, int kf_id,
                                   const unsigned char* descriptors,
                                   int desc_count, int desc_len,
                                   const float* points3d, const float* points2d);
VL_API int  vl_build_index(VLHandle handle);

/* Frame processing */
VL_API VLResult vl_process_frame(VLHandle handle,
                                  const unsigned char* image_data,
                                  int width, int height,
                                  float fx, float fy, float cx, float cy,
                                  int has_last_pose, const float* last_pose_4x4);

/* Frame processing — out-parameter version (avoids struct-return ABI issues on iOS ARM64) */
VL_API void vl_process_frame_out(VLHandle handle,
                                  const unsigned char* image_data,
                                  int width, int height,
                                  float fx, float fy, float cx, float cy,
                                  int has_last_pose, const float* last_pose_4x4,
                                  VLResult* out_result);

/* State management */
VL_API void vl_reset(VLHandle handle);

/* 坐标系对齐变换: 设置预计算的 4×4 row-major Alignment_Transform */
VL_API void vl_set_alignment_transform(VLHandle handle, const float* at_4x4);

/* Debug diagnostics — writes last frame's pipeline stats to out_info */
VL_API void vl_get_debug_info(VLHandle handle, VLDebugInfo* out_info);

#ifdef __cplusplus
}
#endif
