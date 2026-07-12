/**
 * Stub implementation of visual_localizer for iOS Simulator builds.
 * Returns safe defaults (LOST state, identity pose) for all calls.
 */
#include <stdlib.h>
#include <string.h>

typedef void* VLHandle;

typedef struct {
    int state;
    float pose[16];
    float confidence;
    int matched_features;
} VLResult;

static int _stub_counter = 0;

VLHandle vl_create(void) {
    return (VLHandle)(long)(++_stub_counter);
}

void vl_destroy(VLHandle handle) {
    (void)handle;
}

int vl_add_vocabulary_word(VLHandle handle, int word_id,
                           const unsigned char* descriptor, int desc_len,
                           float idf_weight) {
    (void)handle; (void)word_id; (void)descriptor; (void)desc_len; (void)idf_weight;
    return 1;
}

int vl_add_keyframe(VLHandle handle, int kf_id,
                    const float* pose_4x4,
                    const unsigned char* descriptors, int desc_count,
                    const float* points3d, const float* points2d) {
    (void)handle; (void)kf_id; (void)pose_4x4; (void)descriptors;
    (void)desc_count; (void)points3d; (void)points2d;
    return 1;
}

int vl_build_index(VLHandle handle) {
    (void)handle;
    return 1;
}

VLResult vl_process_frame(VLHandle handle,
                          const unsigned char* image_data,
                          int width, int height,
                          float fx, float fy, float cx, float cy,
                          int has_last_pose, const float* last_pose_4x4) {
    (void)handle; (void)image_data; (void)width; (void)height;
    (void)fx; (void)fy; (void)cx; (void)cy;
    (void)has_last_pose; (void)last_pose_4x4;
    VLResult r;
    r.state = 2; /* LOST */
    memset(r.pose, 0, sizeof(r.pose));
    r.pose[0] = r.pose[5] = r.pose[10] = r.pose[15] = 1.0f;
    r.confidence = 0.0f;
    r.matched_features = 0;
    return r;
}

void vl_reset(VLHandle handle) {
    (void)handle;
}
