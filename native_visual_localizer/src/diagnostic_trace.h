#pragma once
// Data experiment only. No exported ABI, ranking, acceptance, or RNG changes.
#include "visual_localizer.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <iomanip>
#include <locale>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace vl_diagnostic {
inline std::string number(double value) {
    if (!std::isfinite(value)) return "null";
    std::ostringstream s;
    s.imbue(std::locale::classic());
    s << std::setprecision(17) << value;
    return s.str();
}
inline std::string boolean(int value) {
    return value < 0 ? "null" : value ? "true" : "false";
}
inline std::string array(const float* values, std::size_t count) {
    std::string result = "[";
    for (std::size_t i = 0; i < count; ++i) {
        if (i) result += ',';
        result += number(values[i]);
    }
    return result + ']';
}
using Clock = std::chrono::steady_clock;
inline double elapsedMs(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
class FrameTrace {
public:
    FrameTrace(std::uint64_t ordinal, VLDebugInfo* debug, FrameTrace*& active, const char* phase = "original", bool emit_frame_end = true)
        : phase_(phase), emit_frame_end_(emit_frame_end), ordinal_(ordinal), debug_(debug), active_(active), previous_(active), start_(Clock::now()) {
        const char* path = std::getenv("VL_DIAGNOSTIC_TRACE");
        // Explicit absolute local path only; refuse a symlink target and fail closed.
        if (path && path[0] == '/' && path[1]) {
            int fd = ::open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
            if (fd >= 0) {
                file_ = ::fdopen(fd, "a");
                if (!file_) ::close(fd);
            }
        }
        active_ = this;
    }
    ~FrameTrace() {
        if (enabled()) {
            if (emit_frame_end_) emit("frame_end", "\"state\":" + std::to_string(state_) +
                ",\"rejection_reason\":\"" + reason_ + "\",\"elapsed_ms\":" + number(elapsedMs(start_)) +
                ",\"candidate_keyframes\":" + std::to_string(debug_->candidate_keyframes) +
                ",\"best_kf_id\":" + std::to_string(debug_->best_kf_id) +
                ",\"matched_features\":" + std::to_string(matched_) +
                ",\"consistency_rejected\":" + boolean(debug_->consistency_rejected) +
                ",\"pose_camera_from_scan\":" + pose_);
            std::fclose(file_);
        }
        active_ = previous_;
    }
    bool enabled() const { return file_ != nullptr; }
    void emit(const char* event, const std::string& fields) {
        if (!enabled()) return;
        const std::string line = "{\"schema_version\":1,\"frame_ordinal\":" +
            std::to_string(ordinal_) + ",\"phase\":\"" + phase_ + "\",\"event\":\"" + event + "\"," + fields + "}\n";
        std::fwrite(line.data(), 1, line.size(), file_);
        std::fflush(file_);
    }
    void result(const VLResult& result, const char* reason) {
        state_ = result.state;
        matched_ = result.matched_features;
        reason_ = reason;
        if (enabled()) pose_ = array(result.pose, 16);
    }
private:
    std::string phase_;
    bool emit_frame_end_;
    std::uint64_t ordinal_;
    VLDebugInfo* debug_;
    FrameTrace*& active_;
    FrameTrace* previous_;
    Clock::time_point start_;
    FILE* file_ = nullptr;
    int state_ = 2;
    int matched_ = 0;
    const char* reason_ = "no_geometric_pose";
    std::string pose_ = "null";
};
class MatchTrace {
public:
    MatchTrace(FrameTrace* frame, const char* path, int kf_id)
        : frame_(frame), path_(path), kf_id_(kf_id), start_(Clock::now()) {}
    bool enabled() const { return frame_ && frame_->enabled(); }
    // Rows follow the exact object/image insertion order passed to PnP.
    // Per-row algorithm/phase are identified by the enclosing match event.
    void correspondence(int query_index, int train_index,
                        float u, float v, float x, float y, float z, float distance) {
        if (!enabled()) return;
        const float values[] = {u, v, x, y, z, distance};
        valid_correspondences.pop_back();
        if (valid_correspondences.size() > 1) valid_correspondences += ',';
        valid_correspondences += "{\"query_index\":" + std::to_string(query_index) +
            ",\"kf_id\":" + std::to_string(kf_id_) +
            ",\"train_index\":" + std::to_string(train_index) +
            ",\"uv_xyz_distance\":" + array(values, 6) + "}]";
    }
    ~MatchTrace() {
        if (!enabled()) return;
        frame_->emit("match", "\"path\":\"" + std::string(path_) + "\",\"kf_id\":" + std::to_string(kf_id_) +
            ",\"raw_knn_matches\":" + std::to_string(raw) +
            ",\"lowe_matches\":" + std::to_string(lowe) +
            ",\"absolute_fallback_used\":" + boolean(absolute_used) +
            ",\"absolute_matches\":" + std::to_string(absolute) +
            ",\"cross_checked_matches\":" + std::to_string(cross_checked) +
            ",\"valid_3d_matches\":" + std::to_string(valid_3d) +
            ((std::string(path_) == "ORB" || std::string(path_) == "AKAZE")
                ? ",\"valid_correspondences\":" + valid_correspondences : "") +
            ",\"pnp_success\":" + boolean(pnp_success) +
            ",\"pnp_inliers\":" + std::to_string(pnp_inliers) +
            ",\"pnp_inlier_indices\":" + inlier_indices +
            ",\"pnp_inlier_ratio\":" + number(inlier_ratio) +
            ",\"pnp_rvec\":" + rvec + ",\"pnp_tvec\":" + tvec +
            ",\"refinement_success\":" + boolean(refinement_success) +
            ",\"reprojection_ransac_rmse_px\":" + number(ransac_rmse) +
            ",\"reprojection_refined_rmse_px\":" + number(refined_rmse) +
            ",\"pose_camera_from_scan\":" + pose +
            ",\"rejection_reason\":\"" + reason + "\",\"elapsed_ms\":" + number(elapsedMs(start_)));
    }
    const char* reason = "empty_descriptors";
    int raw = 0, lowe = 0, absolute = 0, cross_checked = 0, valid_3d = 0;
    int absolute_used = 0, pnp_success = -1, pnp_inliers = 0, refinement_success = -1;
    double inlier_ratio = NAN, ransac_rmse = NAN, refined_rmse = NAN;
    std::string inlier_indices = "[]", rvec = "null", tvec = "null", pose = "null";
    std::string valid_correspondences = "[]";
private:
    FrameTrace* frame_;
    const char* path_;
    int kf_id_;
    Clock::time_point start_;
};
} // namespace vl_diagnostic
