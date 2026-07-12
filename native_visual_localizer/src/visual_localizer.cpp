/**
 * visual_localizer.cpp - C API wrapper for VisualLocalizer C++ class
 *
 * All functions perform NULL handle checks and wrap C++ calls in try-catch(...)
 * to ensure no C++ exceptions cross the C ABI boundary.
 */
#include "visual_localizer_impl.h"

// Helper: create a LOST VLResult with identity pose (safe default)
static VLResult makeSafeLostResult() {
    VLResult r;
    r.state = 2; // LOST
    r.confidence = 0.0f;
    r.matched_features = 0;
    std::fill(std::begin(r.pose), std::end(r.pose), 0.0f);
    r.pose[0] = r.pose[5] = r.pose[10] = r.pose[15] = 1.0f;
    return r;
}

// ---------------------------------------------------------------------------
// vl_create — allocate a new VisualLocalizer, return opaque handle
// ---------------------------------------------------------------------------
VL_API VLHandle vl_create(void) {
    try {
        auto* localizer = new VisualLocalizer();
        return static_cast<VLHandle>(localizer);
    } catch (...) {
        return nullptr;
    }
}

// ---------------------------------------------------------------------------
// vl_destroy — delete the VisualLocalizer behind the handle
// ---------------------------------------------------------------------------
VL_API void vl_destroy(VLHandle handle) {
    if (!handle) return;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        delete localizer;
    } catch (...) {
        // Swallow — destructor should not throw, but guard anyway
    }
}

// ---------------------------------------------------------------------------
// vl_add_vocabulary_word — delegate to handle->addVocabularyWord
// ---------------------------------------------------------------------------
VL_API int vl_add_vocabulary_word(VLHandle handle, int word_id,
                                   const unsigned char* descriptor, int desc_len,
                                   float idf_weight) {
    if (!handle) return 0;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        localizer->addVocabularyWord(word_id, descriptor, desc_len, idf_weight);
        return 1;
    } catch (...) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// vl_add_keyframe — delegate to handle->addKeyframe
// ---------------------------------------------------------------------------
VL_API int vl_add_keyframe(VLHandle handle, int kf_id,
                            const float* pose_4x4,
                            const unsigned char* descriptors, int desc_count,
                            const float* points3d, const float* points2d) {
    if (!handle) return 0;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        localizer->addKeyframe(kf_id, pose_4x4, descriptors, desc_count,
                               points3d, points2d);
        return 1;
    } catch (...) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// vl_add_keyframe_akaze — delegate to handle->addKeyframeAkaze
// ---------------------------------------------------------------------------
VL_API int vl_add_keyframe_akaze(VLHandle handle, int kf_id,
                                  const unsigned char* descriptors,
                                  int desc_count, int desc_len,
                                  const float* points3d, const float* points2d) {
    if (!handle) return 0;
    if (!descriptors || !points3d || !points2d) return 0;
    if (desc_count <= 0 || desc_len <= 0) return 0;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        localizer->addKeyframeAkaze(kf_id, descriptors, desc_count, desc_len,
                                    points3d, points2d);
        return 1;
    } catch (...) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// vl_build_index — delegate to handle->buildIndex
// ---------------------------------------------------------------------------
VL_API int vl_build_index(VLHandle handle) {
    if (!handle) return 0;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        return localizer->buildIndex() ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// vl_process_frame — delegate to handle->processFrame with full param checks
// ---------------------------------------------------------------------------
VL_API VLResult vl_process_frame(VLHandle handle,
                                  const unsigned char* image_data,
                                  int width, int height,
                                  float fx, float fy, float cx, float cy,
                                  int has_last_pose,
                                  const float* last_pose_4x4) {
    VLResult lost = makeSafeLostResult();

    if (!handle) return lost;
    if (!image_data || width <= 0 || height <= 0) return lost;

    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        return localizer->processFrame(image_data, width, height,
                                       fx, fy, cx, cy,
                                       has_last_pose != 0, last_pose_4x4);
    } catch (...) {
        return lost;
    }
}

// ---------------------------------------------------------------------------
// vl_reset — delegate to handle->reset
// ---------------------------------------------------------------------------
VL_API void vl_reset(VLHandle handle) {
    if (!handle) return;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        localizer->reset();
    } catch (...) {
        // Swallow
    }
}

// ---------------------------------------------------------------------------
// vl_process_frame_out — out-parameter version to avoid struct-return ABI
//                        issues on iOS ARM64 with IL2CPP
// ---------------------------------------------------------------------------
VL_API void vl_process_frame_out(VLHandle handle,
                                  const unsigned char* image_data,
                                  int width, int height,
                                  float fx, float fy, float cx, float cy,
                                  int has_last_pose,
                                  const float* last_pose_4x4,
                                  VLResult* out_result) {
    VLResult lost = makeSafeLostResult();

    if (!out_result) return;
    if (!handle || !image_data || width <= 0 || height <= 0) {
        *out_result = lost;
        return;
    }

    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        *out_result = localizer->processFrame(image_data, width, height,
                                               fx, fy, cx, cy,
                                               has_last_pose != 0, last_pose_4x4);
    } catch (...) {
        *out_result = lost;
    }
}

// ---------------------------------------------------------------------------
// vl_set_alignment_transform — set pre-computed 4×4 Alignment_Transform
// ---------------------------------------------------------------------------
VL_API void vl_set_alignment_transform(VLHandle handle, const float* at_4x4) {
    if (!handle) return;
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        localizer->setAlignmentTransform(at_4x4);
    } catch (...) {
        // Swallow
    }
}

// ---------------------------------------------------------------------------
// vl_get_debug_info — write last frame's pipeline diagnostics to out_info
// ---------------------------------------------------------------------------
VL_API void vl_get_debug_info(VLHandle handle, VLDebugInfo* out_info) {
    VLDebugInfo empty = {};
    empty.best_kf_id = -1;
    if (!out_info) return;
    if (!handle) { *out_info = empty; return; }
    try {
        auto* localizer = static_cast<VisualLocalizer*>(handle);
        *out_info = localizer->getDebugInfo();
    } catch (...) {
        *out_info = empty;
    }
}
