#include "visual_localizer_impl.h"
#include "pose_contract.h"
#include "final_geometry.h"
#if CV_VERSION_MAJOR >= 5
#include <opencv2/geometry.hpp>
#else
#include <opencv2/calib3d.hpp>
#endif
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <climits>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <unordered_map>
#include <set>

// ---------------------------------------------------------------------------
// Helper: create a LOST VLResult with identity pose
// ---------------------------------------------------------------------------
static VLResult makeLostResult() {
    VLResult r;
    r.state = 2; // LOST
    r.confidence = 0.0f;
    r.matched_features = 0;
    std::fill(std::begin(r.pose), std::end(r.pose), 0.0f);
    r.pose[0] = r.pose[5] = r.pose[10] = r.pose[15] = 1.0f; // identity
    return r;
}

static void traceFinalGeometry(vl_diagnostic::FrameTrace* trace, const char* path,
    int keyframe, const final_geometry::Validation& geometry, const cv::Mat& tvec,
    int inlier_count) {
    if (!trace || !trace->enabled()) return;
    std::string candidate_pose="null";
    if (!geometry.rotation.empty()) {
        const auto pose=visual_localizer::pose_contract::cameraFromScanFromOpenCvPnP(geometry.rotation,tvec);
        candidate_pose=vl_diagnostic::array(pose.ptr<float>(),16);
    }
    trace->emit("final_geometry", "\"path\":\""+std::string(path)+"\",\"kf_id\":"+std::to_string(keyframe)+
        ",\"accepted\":"+vl_diagnostic::boolean(geometry.accepted)+
        ",\"rejection_reason\":\""+geometry.reason+"\",\"selected_inlier_count\":"+std::to_string(inlier_count)+
        ",\"candidate_pose_camera_from_scan\":"+candidate_pose+
        ",\"checked_minimum_optical_depth_m\":"+vl_diagnostic::number(geometry.minimum_depth)+
        ",\"checked_maximum_original_px\":"+vl_diagnostic::number(geometry.maximum_error));
}

// Diagnostic only: Euclidean pixel RMSE of the actual refined RANSAC inliers.
// Selection stores this alongside its candidate; algorithm scores are unchanged.
static ReprojectionMetric reprojectionMetric(const std::vector<cv::Point3f>& object,
    const std::vector<cv::Point2f>& image, const cv::Mat& rvec, const cv::Mat& tvec,
    const cv::Mat& camera, const cv::Mat& inliers) {
    ReprojectionMetric metric;
    if(inliers.empty()) return metric;
    std::vector<cv::Point3f> selected;
    selected.reserve(inliers.rows);
    for(int i=0;i<inliers.rows;++i) selected.push_back(object[inliers.at<int>(i,0)]);
    std::vector<cv::Point2f> projected;
    cv::projectPoints(selected,rvec,tvec,camera,cv::noArray(),projected);
    double squared=0;
    for(int i=0;i<inliers.rows;++i){
        const auto& target=image[inliers.at<int>(i,0)];
        const double dx=projected[i].x-target.x,dy=projected[i].y-target.y;
        squared+=dx*dx+dy*dy;
    }
    const double rmse=std::sqrt(squared/inliers.rows);
    if(std::isfinite(rmse)){metric.rmse_px=static_cast<float>(rmse);metric.valid=true;}
    return metric;
}

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------
VisualLocalizer::VisualLocalizer()
    : orb_(cv::ORB::create(kOrbNFeatures))
    , matcher_(cv::BFMatcher::create(cv::NORM_HAMMING))
    , index_built_(false)
    , akaze_(VisualLocalizerAkaze::create())
    , akaze_matcher_(cv::BFMatcher::create(cv::NORM_HAMMING))
{
}

VisualLocalizer::~VisualLocalizer() = default;

// ---------------------------------------------------------------------------
// addVocabularyWord — deep-copy a single vocabulary word
// ---------------------------------------------------------------------------
void VisualLocalizer::addVocabularyWord(int word_id, const unsigned char* desc,
                                         int desc_len, float idf_weight) {
    VocabWord w;
    w.word_id = word_id;
    w.descriptor.assign(desc, desc + desc_len);
    w.idf_weight = idf_weight;
    vocabulary_.push_back(std::move(w));
}

// ---------------------------------------------------------------------------
// addKeyframe — deep-copy pose, descriptors, 3D/2D points; compute BoW
// ---------------------------------------------------------------------------
void VisualLocalizer::addKeyframe(int kf_id, const float* pose_4x4,
                                   const unsigned char* descriptors,
                                   int desc_count,
                                   const float* points3d,
                                   const float* points2d) {
    KeyframeData kf;
    kf.id = kf_id;

    // Deep-copy 4x4 pose (row-major float)
    kf.pose = cv::Mat(4, 4, CV_32F);
    std::memcpy(kf.pose.data, pose_4x4, 16 * sizeof(float));

    // Deep-copy ORB descriptors (each 32 bytes)
    kf.descriptors = cv::Mat(desc_count, 32, CV_8UC1);
    std::memcpy(kf.descriptors.data, descriptors,
                static_cast<size_t>(desc_count) * 32);

    // Deep-copy 3D points (x,y,z per point)
    kf.points3d.resize(desc_count);
    for (int i = 0; i < desc_count; i++) {
        kf.points3d[i] = cv::Point3f(points3d[i * 3],
                                      points3d[i * 3 + 1],
                                      points3d[i * 3 + 2]);
    }

    // Deep-copy 2D points (x,y per point)
    kf.points2d.resize(desc_count);
    for (int i = 0; i < desc_count; i++) {
        kf.points2d[i] = cv::Point2f(points2d[i * 2],
                                      points2d[i * 2 + 1]);
    }

    // Compute BoW global descriptor for this keyframe
    kf.global_descriptor = computeBoW(kf.descriptors);

    keyframes_.push_back(std::move(kf));
    akaze_candidate_cursor_ = 0;
    last_successful_akaze_keyframe_id_ = -1;
}

// ---------------------------------------------------------------------------
// buildIndex — mark data loading complete
// ---------------------------------------------------------------------------
bool VisualLocalizer::buildIndex() {
    index_built_ = true;
    akaze_candidate_cursor_ = 0;
    last_successful_akaze_keyframe_id_ = -1;
    return true;
}

// ---------------------------------------------------------------------------
// reset — clear tracking state
// ---------------------------------------------------------------------------
void VisualLocalizer::reset() {
    last_reprojection_metric_ = {};
    frame_history_.clear();
    last_scan_from_camera_.release();
    has_last_scan_from_camera_ = false;
    akaze_candidate_cursor_ = 0;
    last_successful_akaze_keyframe_id_ = -1;
}

// ---------------------------------------------------------------------------
// setAlignmentTransform — validate the legacy 4×4 alignment ABI payload.
// It intentionally does not modify the canonical native T_C_S PnP result.
// Runtime composition of T_U_S is introduced in phase-1 task 4.
// ---------------------------------------------------------------------------
void VisualLocalizer::setAlignmentTransform(const float* at_4x4) {
    if (!at_4x4)
        return;

    // Check for NaN values
    for (int i = 0; i < 16; i++) {
        if (std::isnan(at_4x4[i]))
            return;
    }

    // Copy into cv::Mat for validation
    cv::Mat at(4, 4, CV_32F);
    std::memcpy(at.data, at_4x4, 16 * sizeof(float));

    // Extract 3×3 rotation sub-matrix
    cv::Mat R = at(cv::Rect(0, 0, 3, 3));

    // Check R^T * R ≈ I (orthogonality)
    cv::Mat RtR = R.t() * R;
    cv::Mat I3 = cv::Mat::eye(3, 3, CV_32F);
    cv::Mat diff = RtR - I3;
    float ortho_err = static_cast<float>(cv::norm(diff, cv::NORM_L2));
    if (ortho_err > 0.1f)
        return;

    // Check det(R) ≈ +1 (proper rotation, not reflection)
    float det = static_cast<float>(cv::determinant(R));
    if (std::fabs(det - 1.0f) > 0.1f)
        return;

    // Check last row ≈ [0, 0, 0, 1]
    if (std::fabs(at.at<float>(3, 0)) > 1e-4f ||
        std::fabs(at.at<float>(3, 1)) > 1e-4f ||
        std::fabs(at.at<float>(3, 2)) > 1e-4f ||
        std::fabs(at.at<float>(3, 3) - 1.0f) > 1e-4f)
        return;

    // Valid input is accepted for ABI compatibility. Do not retain or apply it:
    // multiplying it into VLResult.pose would violate the T_C_S contract.
}

// ---------------------------------------------------------------------------
// processFrame — full localization pipeline for a single grayscale frame
// ---------------------------------------------------------------------------
// Roll back every state that can influence a later original-resolution frame.
// Snapshots are taken AFTER that frame's original pass; selected diagnostics
// are copied out only after rollback, while history/caches never use fallback.
struct VisualLocalizer::FallbackStateGuard {
    VisualLocalizer& v;
    bool has_last;
    cv::Mat last_pose;
    std::deque<FrameHistory> history;
    std::size_t cursor;
    int last_akaze;
    std::uint64_t ordinal, rng;
    VLDebugInfo debug;
    ReprojectionMetric metric;
    explicit FallbackStateGuard(VisualLocalizer& owner)
        : v(owner), has_last(v.has_last_scan_from_camera_), last_pose(v.last_scan_from_camera_.clone()),
          history(v.frame_history_), cursor(v.akaze_candidate_cursor_),
          last_akaze(v.last_successful_akaze_keyframe_id_), ordinal(v.diagnostic_frame_ordinal_),
          rng(cv::theRNG().state), debug(v.last_debug_info_), metric(v.last_reprojection_metric_) {
        for (auto& frame : history) {
            frame.camera_from_scan = frame.camera_from_scan.clone();
            frame.unity_world_from_scan = frame.unity_world_from_scan.clone();
        }
    }
    ~FallbackStateGuard() {
        v.has_last_scan_from_camera_ = has_last;
        v.last_scan_from_camera_ = std::move(last_pose);
        v.frame_history_ = std::move(history);
        v.akaze_candidate_cursor_ = cursor;
        v.last_successful_akaze_keyframe_id_ = last_akaze;
        v.diagnostic_frame_ordinal_ = ordinal;
        cv::theRNG().state = rng;
        v.last_debug_info_ = debug;
        v.last_reprojection_metric_ = metric;
    }
};

VLResult VisualLocalizer::processFrame(const unsigned char* image_data,
    int width, int height, float fx, float fy, float cx, float cy,
    bool has_unity_world_from_camera, const float* unity_world_from_camera_4x4) {
    const bool pool_enabled = recovery_mode_ == 1 && !has_unity_world_from_camera;
    PoolCapture capture;
    struct CaptureScope {
        PoolCapture*& active; PoolCapture* previous;
        CaptureScope(PoolCapture*& slot, PoolCapture* value) : active(slot), previous(slot) { active=value; }
        ~CaptureScope() { active=previous; }
    } capture_scope(pool_capture_, pool_enabled ? &capture : nullptr);
    const std::uint64_t ordinal = ++diagnostic_frame_ordinal_;
    const VLResult original = processFrameCore(image_data,width,height,fx,fy,cx,cy,
        has_unity_world_from_camera,unity_world_from_camera_4x4,QueryPass::Original,ordinal);
    const bool enabled = recovery_mode_ == 1;
    const bool eligible = enabled && original.state == 2 && !last_debug_info_.consistency_rejected &&
        image_data && width > 0 && height > 0 && std::max(width,height) > 1600;
    VLResult chosen = original;
    bool attempted = false, selected = false, exception = false;
    if (eligible) {
        attempted = true;
        VLResult fallback = makeLostResult();
        VLDebugInfo fallback_debug = {};
        ReprojectionMetric fallback_metric;
        try {
            FallbackStateGuard rollback(*this);
            fallback = processFrameCore(image_data,width,height,fx,fy,cx,cy,
                has_unity_world_from_camera,unity_world_from_camera_4x4,QueryPass::ScaledFallback,ordinal);
            fallback_debug = last_debug_info_;
            fallback_metric = last_reprojection_metric_;
        } catch (...) { exception = true; }
        if (!exception && fallback.state == 1) {
            chosen = fallback;
            last_debug_info_ = fallback_debug;
            last_reprojection_metric_ = fallback_metric;
            selected = true;
        }
    }
    bool joint_selected = false, joint_attempted = false, joint_exception = false;
    if (pool_enabled && !exception && chosen.state == 2 && !last_debug_info_.consistency_rejected &&
        image_data && width > 0 && height > 0) {
        joint_attempted = true;
        VLResult joint = makeLostResult();
        VLDebugInfo joint_debug = {};
        ReprojectionMetric joint_metric;
        try {
            FallbackStateGuard rollback(*this);
            vl_diagnostic::FrameTrace trace(ordinal,&last_debug_info_,diagnostic_trace_,"joint_pool",false);
            for (int grid=0; grid<2; ++grid) for (int algorithm=0; algorithm<2; ++algorithm) {
                const auto& pool = algorithm ? capture.akaze[grid] : capture.orb[grid];
                const char* name = grid ? (algorithm ? "AKAZE_scaled" : "ORB_scaled") :
                    (algorithm ? "AKAZE_original" : "ORB_original");
                ReprojectionMetric metric;
                const auto result=tryJointPool(pool,width,height,fx,fy,cx,cy,name,algorithm ? capture.seen_akaze[grid] : capture.seen_orb[grid],&metric);
                if (result.state == 1 && result.matched_features > joint.matched_features) {
                    joint=result; joint_debug=last_debug_info_; joint_metric=metric;
                }
            }
        } catch (...) { joint_exception = true; joint=makeLostResult(); }
        if (joint.state == 1) {
            chosen=joint; last_debug_info_=joint_debug; last_reprojection_metric_=joint_metric;
            joint_selected=true;
        }
    }
    // No second ordinal and no extra frame_end: internal passes are explicit.
    vl_diagnostic::FrameTrace decision(ordinal,&last_debug_info_,diagnostic_trace_,"selection",false);
    if (decision.enabled()) decision.emit("chosen_result",
        "\"chosen_phase\":\"" + std::string(joint_selected ? "joint_pool" : selected ? "scaled_fallback" : "original") +
        "\",\"recovery_mode\":" + std::to_string(recovery_mode_) +
        ",\"fallback_enabled\":" + vl_diagnostic::boolean(enabled) +
        ",\"fallback_attempted\":" + vl_diagnostic::boolean(attempted) +
        ",\"fallback_exception\":" + vl_diagnostic::boolean(exception) +
        ",\"joint_enabled\":" + vl_diagnostic::boolean(pool_enabled) +
        ",\"joint_attempted\":" + vl_diagnostic::boolean(joint_attempted) +
        ",\"joint_exception\":" + vl_diagnostic::boolean(joint_exception) +
        ",\"state\":" + std::to_string(chosen.state) +
        ",\"matched_features\":" + std::to_string(chosen.matched_features) +
        ",\"best_kf_id\":" + std::to_string(last_debug_info_.best_kf_id) +
        ",\"pose_camera_from_scan\":" + vl_diagnostic::array(chosen.pose,16) +
        ",\"reprojection_valid\":" + vl_diagnostic::boolean(last_reprojection_metric_.valid) +
        ",\"reprojection_rmse_original_px\":" + vl_diagnostic::number(last_reprojection_metric_.rmse_px));
    return chosen;
}

VLResult VisualLocalizer::processFrameCore(const unsigned char* image_data,
    int width, int height, float fx, float fy, float cx, float cy,
    bool has_unity_world_from_camera, const float* unity_world_from_camera_4x4,
    QueryPass pass, std::uint64_t ordinal) {
    VLResult lost = makeLostResult();
    if (pool_capture_) pool_capture_->pass = pass == QueryPass::Original ? 0 : 1;

    // Reset debug info
    last_debug_info_ = {};
    last_reprojection_metric_ = {};
    last_debug_info_.best_kf_id = -1;

    vl_diagnostic::FrameTrace trace(ordinal, &last_debug_info_, diagnostic_trace_,
        pass == QueryPass::Original ? "original" : "scaled_fallback");
    if (trace.enabled()) trace.emit("frame_start", "\"width\":" + std::to_string(width) +
        ",\"height\":" + std::to_string(height) + ",\"fx\":" + vl_diagnostic::number(fx) +
        ",\"fy\":" + vl_diagnostic::number(fy) + ",\"cx\":" + vl_diagnostic::number(cx) +
        ",\"cy\":" + vl_diagnostic::number(cy) +
        ",\"has_last_pose\":" + vl_diagnostic::boolean(has_last_scan_from_camera_) +
        ",\"has_current_ar_pose\":" + vl_diagnostic::boolean(has_unity_world_from_camera));
    if (!image_data || width <= 0 || height <= 0) {
        trace.result(lost, "invalid_image");
        return lost;
    }

    // Step 1: Wrap image data as cv::Mat (zero-copy)
    cv::Mat gray(height, width, CV_8UC1,
                 const_cast<unsigned char*>(image_data));

    // Keep PnP K and its 12-pixel gate on the ORIGINAL grid. Only descriptor
    // extraction is normalized; actual rounded x/y scales are undone on points.
    double scale_x = 1.0, scale_y = 1.0;
    if (pass == QueryPass::ScaledFallback) {
        const double scale = 1600.0 / std::max(width,height);
        const cv::Size size(std::max(1,cvRound(width*scale)),std::max(1,cvRound(height*scale)));
        cv::Mat resized;
        cv::resize(gray,resized,size,0,0,cv::INTER_AREA);
        scale_x = static_cast<double>(size.width)/width;
        scale_y = static_cast<double>(size.height)/height;
        gray = resized;
    }
    if (trace.enabled()) {
        const float intrinsics[] = {fx,fy,cx,cy};
        trace.emit("query_pixel_grid", "\"original_dimensions\":[" + std::to_string(width) + ',' + std::to_string(height) +
            "],\"processed_dimensions\":[" + std::to_string(gray.cols) + ',' + std::to_string(gray.rows) +
            "],\"original_intrinsics\":" + vl_diagnostic::array(intrinsics,4) +
            ",\"pnp_intrinsics\":" + vl_diagnostic::array(intrinsics,4) +
            ",\"scale_xy\":[" + vl_diagnostic::number(scale_x) + ',' + vl_diagnostic::number(scale_y) +
            "],\"pnp_coordinate_grid\":\"original\",\"pnp_reprojection_gate_original_px\":12," +
            "\"keypoint_remap_to_original\":" + vl_diagnostic::boolean(pass == QueryPass::ScaledFallback) +
            ",\"interpolation\":\"" + std::string(pass == QueryPass::ScaledFallback ? "INTER_AREA" : "NONE") + "\"");
    }

    // Step 1.5: CLAHE preprocessing — reduce cross-session lighting differences
    cv::Mat enhanced;
    auto clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    const auto preprocess_start = vl_diagnostic::Clock::now();
    clahe->apply(gray, enhanced);
    if (trace.enabled()) trace.emit("preprocess", "\"elapsed_ms\":" + vl_diagnostic::number(vl_diagnostic::elapsedMs(preprocess_start)));

    // Step 2: ORB detect + compute
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    const auto orb_start = vl_diagnostic::Clock::now();
    orb_->detectAndCompute(enhanced, cv::noArray(), keypoints, descriptors);
    if (pass == QueryPass::ScaledFallback) for (auto& kp : keypoints) {
        kp.pt.x = static_cast<float>(kp.pt.x / scale_x);
        kp.pt.y = static_cast<float>(kp.pt.y / scale_y);
    }
    if (trace.enabled()) trace.emit("features", "\"path\":\"ORB\",\"keypoints\":" + std::to_string(keypoints.size()) +
        ",\"descriptor_rows\":" + std::to_string(descriptors.rows) +
        ",\"elapsed_ms\":" + vl_diagnostic::number(vl_diagnostic::elapsedMs(orb_start)));

    last_debug_info_.orb_keypoints = static_cast<int>(keypoints.size());

    const bool usable_orb = static_cast<int>(keypoints.size()) >= kMinFeatureCount &&
                            !descriptors.empty();

    // Step 3: Candidate keyframe selection
    std::vector<KeyframeData*> candidates;
    bool nearby_candidates = false;
    if (usable_orb) {
        if (has_last_scan_from_camera_) {
            candidates = getNearbyKeyframes(last_scan_from_camera_.ptr<float>(),
                                             kNearbyRadius, kMaxNearbyKeyframes);
            nearby_candidates = !candidates.empty();
        }
        if (candidates.empty())
            candidates = getGlobalCandidates(descriptors);
    }
    bool independent_akaze = !usable_orb || candidates.empty();

    // Step 4: Try matching each candidate, keep best by inlier count
    VLResult best = lost;
    int best_inliers = 0;
    int best_raw = 0, best_good = 0;
    int winner_raw = 0, winner_good = 0;
    ReprojectionMetric winner_metric;

    const auto match_orb = [&](KeyframeData* kf) {
        int raw_matches = 0, good_matches_count = 0;
        ReprojectionMetric candidate_metric;
        VLResult result = tryMatchKeyframe(*kf, keypoints, descriptors,
                                            fx, fy, cx, cy,
                                            &raw_matches, &good_matches_count, &candidate_metric);
        if (raw_matches > best_raw) best_raw = raw_matches;
        if (good_matches_count > best_good) {
            best_good = good_matches_count;
        }
        if (result.state == 1 && result.matched_features > best_inliers) {
            best = result;
            best_inliers = result.matched_features;
            winner_raw = raw_matches;
            winner_good = good_matches_count;
            winner_metric = candidate_metric;
            last_debug_info_.best_kf_id = kf->id;
        }
    };
    for (auto* kf : candidates) match_orb(kf);

    // A non-empty nearby set is only a fast-path hint. If it fails, use the
    // existing BoW retrieval and geometrically verify previously untried frames.
    if (best.state != 1 && nearby_candidates) {
        const auto global = getGlobalCandidates(descriptors);
        independent_akaze = global.empty();
        for (auto* kf : global) {
            if (std::find(candidates.begin(), candidates.end(), kf) != candidates.end())
                continue;
            candidates.push_back(kf);
            match_orb(kf);
        }
    }

    last_debug_info_.best_raw_matches = best.state == 1 ? winner_raw : best_raw;
    last_debug_info_.best_good_matches = best.state == 1 ? winner_good : best_good;
    last_debug_info_.best_inliers = best_inliers;
    last_debug_info_.best_inlier_ratio = (winner_good > 0)
        ? static_cast<float>(best_inliers) / static_cast<float>(winner_good)
        : 0.0f;

    // -----------------------------------------------------------------------
    // AKAZE Fallback: ORB 全部失败 且 akaze_keyframes_ 非空时触发
    // -----------------------------------------------------------------------
    if (best.state != 1 && !akaze_keyframes_.empty()) {
        last_debug_info_.akaze_triggered = 1;
        auto akaze_candidates = independent_akaze ? getIndependentAkazeCandidates() : candidates;
        if (trace.enabled()) {
            std::string ids = "[";
            for (std::size_t i = 0; i < akaze_candidates.size(); ++i) {
                if (i) ids += ',';
                ids += std::to_string(akaze_candidates[i]->id);
            }
            trace.emit("akaze_candidates", "\"source\":\"" + std::string(independent_akaze ? "independent_batch" : "orb_shortlist") +
                "\",\"candidate_ids\":" + ids + "]");
        }
        for (auto* kf : akaze_candidates) {
            if (std::find(candidates.begin(), candidates.end(), kf) == candidates.end())
                candidates.push_back(kf);
        }
        VLResult akaze_result = tryAkazeFallback(enhanced, akaze_candidates,
                                                  fx, fy, cx, cy, &winner_metric, scale_x, scale_y);
        if (akaze_result.state == 1) {
            best = akaze_result;
            best_inliers = akaze_result.matched_features;
            last_debug_info_.akaze_best_inliers = akaze_result.matched_features;
        }
    }
    last_debug_info_.candidate_keyframes = static_cast<int>(candidates.size());

    // -----------------------------------------------------------------------
    // 多帧一致性过滤: 用 T_U_S 误差的 median + 3×MAD 阈值剔除离群帧
    // -----------------------------------------------------------------------
    if (best.state == 1 && has_unity_world_from_camera &&
        unity_world_from_camera_4x4) {
        // T_C_S from native PnP (row-major float[16]).
        cv::Mat camera_from_scan(4, 4, CV_32F);
        std::memcpy(camera_from_scan.data, best.pose, 16 * sizeof(float));

        // T_U_C from the current AR frame (row-major float[16]).
        cv::Mat unity_world_from_camera(4, 4, CV_32F);
        std::memcpy(unity_world_from_camera.data,
                    unity_world_from_camera_4x4, 16 * sizeof(float));

        // T_U_S = T_U_C × T_C_S
        cv::Mat unity_world_from_scan = unity_world_from_camera * camera_from_scan;

        // ‖T_U_S − I‖_F
        cv::Mat identity = cv::Mat::eye(4, 4, CV_32F);
        cv::Mat diff = unity_world_from_scan - identity;
        float unity_world_from_scan_error =
            static_cast<float>(cv::norm(diff, cv::NORM_L2));

        if (static_cast<int>(frame_history_.size()) < 3) {
            // 冷启动: 跳过过滤，直接接受
            FrameHistory fh;
            fh.camera_from_scan = camera_from_scan.clone();
            fh.unity_world_from_scan = unity_world_from_scan.clone();
            fh.unity_world_from_scan_error = unity_world_from_scan_error;
            frame_history_.push_back(std::move(fh));
            if (static_cast<int>(frame_history_.size()) > kMaxHistoryFrames) {
                frame_history_.pop_front();
            }
        } else {
            // 收集历史帧 T_U_S 误差
            std::vector<float> hist_errs;
            hist_errs.reserve(frame_history_.size());
            for (const auto& fh : frame_history_) {
                hist_errs.push_back(fh.unity_world_from_scan_error);
            }

            // 计算 median
            std::vector<float> sorted_errs = hist_errs;
            std::sort(sorted_errs.begin(), sorted_errs.end());
            float median;
            size_t n = sorted_errs.size();
            if (n % 2 == 0) {
                median = (sorted_errs[n / 2 - 1] + sorted_errs[n / 2]) / 2.0f;
            } else {
                median = sorted_errs[n / 2];
            }

            // 计算 MAD (Median Absolute Deviation)
            std::vector<float> abs_devs;
            abs_devs.reserve(n);
            for (float e : hist_errs) {
                abs_devs.push_back(std::fabs(e - median));
            }
            std::sort(abs_devs.begin(), abs_devs.end());
            float mad;
            if (n % 2 == 0) {
                mad = (abs_devs[n / 2 - 1] + abs_devs[n / 2]) / 2.0f;
            } else {
                mad = abs_devs[n / 2];
            }

            // 阈值 = median + kConsistencyMadMultiplier × max(MAD, kConsistencyMinMad)
            float effective_mad = std::max(mad, kConsistencyMinMad);
            float threshold = median + kConsistencyMadMultiplier * effective_mad;

            if (unity_world_from_scan_error > threshold) {
                // 离群帧: 拒绝，返回 LOST
                last_debug_info_.consistency_rejected = 1;
                if (trace.enabled()) trace.emit("consistency", "\"accepted\":false,\"error\":" + vl_diagnostic::number(unity_world_from_scan_error) +
                    ",\"threshold\":" + vl_diagnostic::number(threshold));
                trace.result(lost, "consistency_rejected");
                return lost;
            }

            // 通过一致性检查: 加入历史队列
            FrameHistory fh;
            fh.camera_from_scan = camera_from_scan.clone();
            fh.unity_world_from_scan = unity_world_from_scan.clone();
            fh.unity_world_from_scan_error = unity_world_from_scan_error;
            frame_history_.push_back(std::move(fh));
            if (static_cast<int>(frame_history_.size()) > kMaxHistoryFrames) {
                frame_history_.pop_front();
            }
        }
    } else if (best.state == 1) {
        // 有效定位但无当前 T_U_C: 无法计算 T_U_S，一致性过滤跳过。
    }

    // Cache T_S_C separately for nearby keyframe selection. This must never
    // be substituted for the current T_U_C parameter above.
    if (best.state == 1) {
        last_reprojection_metric_ = winner_metric;
        cv::Mat camera_from_scan(4, 4, CV_32F);
        std::memcpy(camera_from_scan.data, best.pose, 16 * sizeof(float));
        cv::Mat scan_from_camera;
        if (cv::invert(camera_from_scan, scan_from_camera, cv::DECOMP_LU) != 0.0) {
            last_scan_from_camera_ = scan_from_camera;
            has_last_scan_from_camera_ = true;
            last_successful_akaze_keyframe_id_ = last_debug_info_.akaze_triggered
                ? last_debug_info_.best_kf_id : -1;
        }
    }

    trace.result(best, best.state == 1 ? "accepted" : "no_geometric_pose");
    return best;
}

// ---------------------------------------------------------------------------
// tryMatchKeyframe — BFMatcher KNN → Lowe ratio → 3D-2D → PnP RANSAC → pose
// ---------------------------------------------------------------------------
VLResult VisualLocalizer::tryMatchKeyframe(const KeyframeData& kf,
                                            const std::vector<cv::KeyPoint>& query_kps,
                                            const cv::Mat& query_desc,
                                            float fx, float fy,
                                            float cx, float cy,
                                            int* out_raw_matches,
                                            int* out_good_matches, ReprojectionMetric* out_metric) {
    vl_diagnostic::MatchTrace match_trace(diagnostic_trace_, "ORB", kf.id);
    VLResult lost = makeLostResult();
    if (out_raw_matches) *out_raw_matches = 0;
    if (out_good_matches) *out_good_matches = 0;
    if (out_metric) *out_metric = {};

    if (kf.descriptors.empty())
        return lost;

    // KNN match (k=2)
    std::vector<std::vector<cv::DMatch>> knn_matches;
    matcher_->knnMatch(query_desc, kf.descriptors, knn_matches, 2);

    if (out_raw_matches) *out_raw_matches = static_cast<int>(knn_matches.size());

    match_trace.raw = static_cast<int>(knn_matches.size());

    // Lowe ratio test
    std::vector<cv::DMatch> good_matches;
    for (const auto& m : knn_matches) {
        if (m.size() >= 2 &&
            m[0].distance < kLoweRatio * m[1].distance) {
            good_matches.push_back(m[0]);
        }
    }

    match_trace.lowe = static_cast<int>(good_matches.size());

    // Fallback: if Lowe ratio yields too few matches, use absolute distance threshold
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        match_trace.absolute_used = 1;
        good_matches.clear();
        for (const auto& m : knn_matches) {
            if (!m.empty() && m[0].distance < kAbsoluteDistThreshold) {
                good_matches.push_back(m[0]);
            }
        }
    }

    if (match_trace.absolute_used) match_trace.absolute = static_cast<int>(good_matches.size());

    // Cross-check: reverse match (db→query) to filter many-to-one errors
    {
        std::vector<std::vector<cv::DMatch>> reverse_knn;
        matcher_->knnMatch(kf.descriptors, query_desc, reverse_knn, 2);

        // Build reverse match map: for each db descriptor, what query descriptor does it best match to?
        std::unordered_map<int, int> reverse_map; // db_idx -> query_idx
        for (const auto& m : reverse_knn) {
            if (m.size() >= 2 && m[0].distance < kLoweRatio * m[1].distance) {
                reverse_map[m[0].queryIdx] = m[0].trainIdx;
            }
        }

        // Keep only bidirectionally consistent matches
        std::vector<cv::DMatch> cross_checked;
        for (const auto& match : good_matches) {
            auto it = reverse_map.find(match.trainIdx);
            if (it != reverse_map.end() && it->second == match.queryIdx) {
                cross_checked.push_back(match);
            }
        }
        good_matches = std::move(cross_checked);
    }

    if (pool_capture_) for (const auto& m : good_matches) {
        if (m.queryIdx >= 0 && m.queryIdx < static_cast<int>(query_kps.size()) &&
            m.trainIdx >= 0 && m.trainIdx < static_cast<int>(kf.points3d.size()))
        {
            ++pool_capture_->seen_orb[pool_capture_->pass];
            if(pool_capture_->orb[pool_capture_->pass].size()<4096)
                pool_capture_->orb[pool_capture_->pass].push_back({query_kps[m.queryIdx].pt,
                    kf.points3d[m.trainIdx],m.queryIdx,kf.id,m.trainIdx,m.distance});
        }
    }
    match_trace.cross_checked = static_cast<int>(good_matches.size());
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        match_trace.reason = "insufficient_cross_checked_matches";
        return lost;
    }

    if (out_good_matches) *out_good_matches = static_cast<int>(good_matches.size());

    // Build 3D-2D correspondences from good matches
    std::vector<cv::Point3f> obj_pts;
    std::vector<cv::Point2f> img_pts;
    for (const auto& match : good_matches) {
        int kf_idx = match.trainIdx;
        int q_idx = match.queryIdx;
        if (kf_idx < static_cast<int>(kf.points3d.size()) &&
            q_idx < static_cast<int>(query_kps.size())) {
            obj_pts.push_back(kf.points3d[kf_idx]);
            img_pts.push_back(query_kps[q_idx].pt);
            if (match_trace.enabled()) {
                const auto& image = img_pts.back();
                const auto& object = obj_pts.back();
                match_trace.correspondence(q_idx, kf_idx, image.x, image.y,
                                           object.x, object.y, object.z, match.distance);
            }
        }
    }

    match_trace.valid_3d = static_cast<int>(obj_pts.size());
    if (static_cast<int>(obj_pts.size()) < kMinGoodMatches) {
        match_trace.reason = "insufficient_valid_3d_matches";
        return lost;
    }

    // Camera intrinsic matrix
    cv::Mat camera_mat = (cv::Mat_<double>(3, 3) <<
        static_cast<double>(fx), 0.0, static_cast<double>(cx),
        0.0, static_cast<double>(fy), static_cast<double>(cy),
        0.0, 0.0, 1.0);

    // PnP RANSAC
    cv::Mat rvec, tvec, inliers;
    const bool pnp_success = cv::solvePnPRansac(obj_pts, img_pts, camera_mat, cv::noArray(),
                        rvec, tvec, false,
                        kPnpIterations, kPnpReprojError,
                        kPnpConfidence, inliers);

    int inlier_count = inliers.rows;
    match_trace.pnp_success = pnp_success;
    match_trace.pnp_inliers = inlier_count;
    match_trace.inlier_ratio = static_cast<double>(inlier_count) / good_matches.size();
    if (match_trace.enabled()) {
        match_trace.inlier_indices = "[";
        for (int i = 0; i < inliers.rows; ++i) {
            if (i) match_trace.inlier_indices += ',';
            match_trace.inlier_indices += std::to_string(inliers.at<int>(i, 0));
        }
        match_trace.inlier_indices += ']';
        const auto vector_json = [](const cv::Mat& value) {
            std::string json = "[";
            for (std::size_t i = 0; i < value.total(); ++i) {
                if (i) json += ',';
                json += vl_diagnostic::number(value.depth() == CV_64F ? value.ptr<double>()[i] : value.ptr<float>()[i]);
            }
            return json + ']';
        };
        if (!rvec.empty()) match_trace.rvec = vector_json(rvec);
        if (!tvec.empty()) match_trace.tvec = vector_json(tvec);
        if (pnp_success && !inliers.empty() && !rvec.empty() && !tvec.empty()) {
            const auto metric = reprojectionMetric(obj_pts, img_pts, rvec, tvec, camera_mat, inliers);
            if (metric.valid) match_trace.ransac_rmse = metric.rmse_px;
        }
    }
    if (!pnp_success || inlier_count < kMinInlierCount) {
        match_trace.reason = pnp_success ? "insufficient_pnp_inliers" : "pnp_failed";
        return lost;
    }

    if (!final_geometry::validInlierIndices(inliers, obj_pts.size())) {
        match_trace.reason = "invalid_pnp_inlier_indices";
        return lost;
    }

    // Inlier ratio quality gate: reject if too few inliers relative to matches
    int good_count = static_cast<int>(good_matches.size());
    if (good_count > 0) {
        float inlier_ratio = static_cast<float>(inlier_count) / static_cast<float>(good_count);
        if (inlier_ratio < kMinInlierRatio) {
            match_trace.reason = "insufficient_pnp_inlier_ratio";
            return lost;
        }
    }

    // PnP Refinement: 用 RANSAC inlier 做 iterative 精化
    {
        std::vector<cv::Point3f> inlier_obj;
        std::vector<cv::Point2f> inlier_img;
        inlier_obj.reserve(inlier_count);
        inlier_img.reserve(inlier_count);
        for (int i = 0; i < inliers.rows; i++) {
            int idx = inliers.at<int>(i, 0);
            inlier_obj.push_back(obj_pts[idx]);
            inlier_img.push_back(img_pts[idx]);
        }
        cv::Mat rvec_ref = rvec.clone(), tvec_ref = tvec.clone();
        bool ok = cv::solvePnP(inlier_obj, inlier_img, camera_mat, cv::noArray(),
                                rvec_ref, tvec_ref, true, cv::SOLVEPNP_ITERATIVE);
        match_trace.refinement_success = ok;
        if (ok) {
            rvec = rvec_ref;
            tvec = tvec_ref;
        }
        // 精化失败则保留 RANSAC 原始结果
    }

    const auto final = final_geometry::validatePnP(pnp_success, obj_pts, img_pts,
        camera_mat, rvec, tvec, inliers, kPnpReprojError);
    traceFinalGeometry(diagnostic_trace_,"ORB",kf.id,final,tvec,inliers.rows);
    if (!final.accepted) {
        match_trace.reason = final.reason;
        return lost;
    }

    if (out_metric || match_trace.enabled()) {
        const auto metric = reprojectionMetric(obj_pts, img_pts, rvec, tvec, camera_mat, inliers);
        if (out_metric) *out_metric = metric;
        if (metric.valid) match_trace.refined_rmse = metric.rmse_px;
    }

    // solvePnPRansac returns S -> OpenCV-camera. The one OpenCV-camera ->
    // AR-camera normalization is centralized in pose_contract below.
    const cv::Mat& rot_mat = final.rotation;

    VLResult result;
    result.state = 1; // TRACKING
    result.confidence = std::min(1.0f,
        static_cast<float>(inlier_count) / kMaxConfidenceDivisor);
    result.matched_features = inlier_count;

    // Fill T_C_S once as row-major after exactly one normalization.
    const cv::Mat camera_from_scan =
        visual_localizer::pose_contract::cameraFromScanFromOpenCvPnP(rot_mat, tvec);
    std::memcpy(result.pose, camera_from_scan.ptr<float>(), 16 * sizeof(float));

    match_trace.reason = "accepted";
    if (match_trace.enabled()) match_trace.pose = vl_diagnostic::array(result.pose, 16);
    return result;
}

// ---------------------------------------------------------------------------
// addKeyframeAkaze — deep-copy AKAZE descriptors and corresponding 3D/2D pts
// ---------------------------------------------------------------------------
void VisualLocalizer::addKeyframeAkaze(int kf_id,
                                        const unsigned char* descriptors,
                                        int desc_count, int desc_len,
                                        const float* points3d,
                                        const float* points2d) {
    // Validate parameters
    if (desc_count <= 0 || desc_len <= 0)
        return;
    if (!descriptors || !points3d || !points2d)
        return;

    AkazeKeyframeData akd;

    // Deep-copy AKAZE descriptors (desc_count × desc_len, CV_8UC1)
    akd.descriptors = cv::Mat(desc_count, desc_len, CV_8UC1);
    std::memcpy(akd.descriptors.data, descriptors,
                static_cast<size_t>(desc_count) * desc_len);

    // Deep-copy 3D points (x,y,z per point)
    akd.points3d.resize(desc_count);
    for (int i = 0; i < desc_count; i++) {
        akd.points3d[i] = cv::Point3f(points3d[i * 3],
                                       points3d[i * 3 + 1],
                                       points3d[i * 3 + 2]);
    }

    // Deep-copy 2D points (x,y per point)
    akd.points2d.resize(desc_count);
    for (int i = 0; i < desc_count; i++) {
        akd.points2d[i] = cv::Point2f(points2d[i * 2],
                                       points2d[i * 2 + 1]);
    }

    akaze_keyframes_[kf_id] = std::move(akd);
    akaze_candidate_cursor_ = 0;
    last_successful_akaze_keyframe_id_ = -1;
}

// Without usable ORB retrieval, visit a bounded stable batch. Advance through
// insertion order rather than unordered_map order so repeated failures eventually
// cover the map, and loading/resetting restarts the same deterministic sequence.
std::vector<KeyframeData*> VisualLocalizer::getIndependentAkazeCandidates() {
    std::vector<KeyframeData*> candidates;
    if (keyframes_.empty() || akaze_keyframes_.empty())
        return candidates;
    // Keep the last verified AKAZE reference available while the remaining
    // budget continues the search. Otherwise a large map would periodically
    // lose a stationary query solely because its reference rotated out.
    if (last_successful_akaze_keyframe_id_ >= 0) {
        for (auto& keyframe : keyframes_) {
            if (keyframe.id == last_successful_akaze_keyframe_id_) {
                const auto data = akaze_keyframes_.find(keyframe.id);
                if (data != akaze_keyframes_.end() && !data->second.descriptors.empty())
                    candidates.push_back(&keyframe);
                break;
            }
        }
    }
    akaze_candidate_cursor_ %= keyframes_.size();
    std::size_t visited = 0;
    while (visited < keyframes_.size() && candidates.size() < kGlobalTopK) {
        auto& keyframe = keyframes_[akaze_candidate_cursor_];
        akaze_candidate_cursor_ = (akaze_candidate_cursor_ + 1) % keyframes_.size();
        ++visited;
        if (!candidates.empty() && &keyframe == candidates.front())
            continue;
        const auto data = akaze_keyframes_.find(keyframe.id);
        if (data != akaze_keyframes_.end() && !data->second.descriptors.empty())
            candidates.push_back(&keyframe);
    }
    return candidates;
}

// ---------------------------------------------------------------------------
// tryAkazeFallback — AKAZE detectAndCompute on enhanced image, then try
//                    matching against candidates that have AKAZE data.
//                    Returns best result by inlier count, or LOST.
// ---------------------------------------------------------------------------
VLResult VisualLocalizer::tryAkazeFallback(const cv::Mat& enhanced,
                                            const std::vector<KeyframeData*>& candidates,
                                            float fx, float fy,
                                            float cx, float cy, ReprojectionMetric* out_metric, double query_scale_x, double query_scale_y) {
    VLResult lost = makeLostResult();
    if (out_metric) *out_metric = {};

    // 无 AKAZE 数据时不触发 fallback
    if (akaze_keyframes_.empty())
        return lost;

    // AKAZE 特征提取
    std::vector<cv::KeyPoint> akaze_kps;
    cv::Mat akaze_desc;
    const auto akaze_start = vl_diagnostic::Clock::now();
    akaze_->detectAndCompute(enhanced, cv::noArray(), akaze_kps, akaze_desc);
    if (query_scale_x != 1.0 || query_scale_y != 1.0) for (auto& kp : akaze_kps) {
        kp.pt.x = static_cast<float>(kp.pt.x / query_scale_x);
        kp.pt.y = static_cast<float>(kp.pt.y / query_scale_y);
    }
    if (diagnostic_trace_ && diagnostic_trace_->enabled()) diagnostic_trace_->emit("features", "\"path\":\"AKAZE\",\"keypoints\":" + std::to_string(akaze_kps.size()) +
        ",\"descriptor_rows\":" + std::to_string(akaze_desc.rows) +
        ",\"rejection_reason\":\"" + std::string(akaze_kps.empty() || akaze_desc.empty() ? "empty_features" : "usable") +
        "\",\"elapsed_ms\":" + vl_diagnostic::number(vl_diagnostic::elapsedMs(akaze_start)));

    if (akaze_kps.empty() || akaze_desc.empty())
        return lost;

    // 记录 AKAZE 特征点数到 debug info
    last_debug_info_.akaze_keypoints = static_cast<int>(akaze_kps.size());

    // 遍历候选 KF，仅对有 AKAZE 数据的 KF 进行匹配
    VLResult best = lost;
    int best_inliers = 0;

    for (auto* kf : candidates) {
        auto it = akaze_keyframes_.find(kf->id);
        if (it == akaze_keyframes_.end()) {
            if (diagnostic_trace_ && diagnostic_trace_->enabled()) diagnostic_trace_->emit("candidate_skipped",
                "\"path\":\"AKAZE\",\"kf_id\":" + std::to_string(kf->id) + ",\"rejection_reason\":\"missing_akaze_data\"");
            continue;
        }  // 无 AKAZE 数据的 KF 跳过

        int raw = 0, good = 0;
        ReprojectionMetric candidate_metric;
        VLResult result = tryMatchKeyframeAkaze(it->second, akaze_kps, akaze_desc,
                                                 fx, fy, cx, cy,
                                                 &raw, &good, &candidate_metric, kf->id);
        if (result.state == 1 && result.matched_features > best_inliers) {
            best = result;
            best_inliers = result.matched_features;
            if (out_metric) *out_metric = candidate_metric;
            last_debug_info_.best_kf_id = kf->id;
            last_debug_info_.best_raw_matches = raw;
            last_debug_info_.best_good_matches = good;
            last_debug_info_.best_inliers = result.matched_features;
            last_debug_info_.best_inlier_ratio = good > 0
                ? static_cast<float>(result.matched_features) / good : 0.f;
        }
    }

    return best;
}

// ---------------------------------------------------------------------------
// tryMatchKeyframeAkaze — same pipeline as tryMatchKeyframe but for AKAZE:
//   BFMatcher KNN → Lowe ratio → cross-check → 3D-2D → PnP RANSAC →
//   refinement → pose
// ---------------------------------------------------------------------------
VLResult VisualLocalizer::tryMatchKeyframeAkaze(
    const AkazeKeyframeData& akaze_kf,
    const std::vector<cv::KeyPoint>& query_kps,
    const cv::Mat& query_desc,
    float fx, float fy, float cx, float cy,
    int* out_raw, int* out_good, ReprojectionMetric* out_metric, int diagnostic_kf_id) {

    vl_diagnostic::MatchTrace match_trace(diagnostic_trace_, "AKAZE", diagnostic_kf_id);
    VLResult lost = makeLostResult();
    if (out_raw) *out_raw = 0;
    if (out_good) *out_good = 0;
    if (out_metric) *out_metric = {};

    if (akaze_kf.descriptors.empty())
        return lost;

    // KNN match (k=2) using AKAZE matcher (NORM_HAMMING)
    std::vector<std::vector<cv::DMatch>> knn_matches;
    akaze_matcher_->knnMatch(query_desc, akaze_kf.descriptors, knn_matches, 2);

    if (out_raw) *out_raw = static_cast<int>(knn_matches.size());

    match_trace.raw = static_cast<int>(knn_matches.size());

    // Lowe ratio test
    std::vector<cv::DMatch> good_matches;
    for (const auto& m : knn_matches) {
        if (m.size() >= 2 &&
            m[0].distance < kLoweRatio * m[1].distance) {
            good_matches.push_back(m[0]);
        }
    }

    match_trace.lowe = static_cast<int>(good_matches.size());

    // Fallback: absolute distance threshold (same as ORB path)
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        match_trace.absolute_used = 1;
        good_matches.clear();
        for (const auto& m : knn_matches) {
            if (!m.empty() && m[0].distance < kAbsoluteDistThreshold) {
                good_matches.push_back(m[0]);
            }
        }
    }

    if (match_trace.absolute_used) match_trace.absolute = static_cast<int>(good_matches.size());

    // Cross-check: reverse match (db→query) to filter many-to-one errors
    {
        std::vector<std::vector<cv::DMatch>> reverse_knn;
        akaze_matcher_->knnMatch(akaze_kf.descriptors, query_desc, reverse_knn, 2);

        std::unordered_map<int, int> reverse_map; // db_idx -> query_idx
        for (const auto& m : reverse_knn) {
            if (m.size() >= 2 && m[0].distance < kLoweRatio * m[1].distance) {
                reverse_map[m[0].queryIdx] = m[0].trainIdx;
            }
        }

        std::vector<cv::DMatch> cross_checked;
        for (const auto& match : good_matches) {
            auto it = reverse_map.find(match.trainIdx);
            if (it != reverse_map.end() && it->second == match.queryIdx) {
                cross_checked.push_back(match);
            }
        }
        good_matches = std::move(cross_checked);
    }

    if (pool_capture_) for (const auto& m : good_matches) {
        if (m.queryIdx >= 0 && m.queryIdx < static_cast<int>(query_kps.size()) &&
            m.trainIdx >= 0 && m.trainIdx < static_cast<int>(akaze_kf.points3d.size()))
        {
            ++pool_capture_->seen_akaze[pool_capture_->pass];
            if(pool_capture_->akaze[pool_capture_->pass].size()<4096)
                pool_capture_->akaze[pool_capture_->pass].push_back({query_kps[m.queryIdx].pt,
                    akaze_kf.points3d[m.trainIdx],m.queryIdx,diagnostic_kf_id,m.trainIdx,m.distance});
        }
    }
    match_trace.cross_checked = static_cast<int>(good_matches.size());
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        match_trace.reason = "insufficient_cross_checked_matches";
        return lost;
    }

    if (out_good) *out_good = static_cast<int>(good_matches.size());

    // Build 3D-2D correspondences from good matches
    std::vector<cv::Point3f> obj_pts;
    std::vector<cv::Point2f> img_pts;
    for (const auto& match : good_matches) {
        int kf_idx = match.trainIdx;
        int q_idx = match.queryIdx;
        if (kf_idx < static_cast<int>(akaze_kf.points3d.size()) &&
            q_idx < static_cast<int>(query_kps.size())) {
            obj_pts.push_back(akaze_kf.points3d[kf_idx]);
            img_pts.push_back(query_kps[q_idx].pt);
            if (match_trace.enabled()) {
                const auto& image = img_pts.back();
                const auto& object = obj_pts.back();
                match_trace.correspondence(q_idx, kf_idx, image.x, image.y,
                                           object.x, object.y, object.z, match.distance);
            }
        }
    }

    match_trace.valid_3d = static_cast<int>(obj_pts.size());
    if (static_cast<int>(obj_pts.size()) < kMinGoodMatches) {
        match_trace.reason = "insufficient_valid_3d_matches";
        return lost;
    }

    // Camera intrinsic matrix
    cv::Mat camera_mat = (cv::Mat_<double>(3, 3) <<
        static_cast<double>(fx), 0.0, static_cast<double>(cx),
        0.0, static_cast<double>(fy), static_cast<double>(cy),
        0.0, 0.0, 1.0);

    // PnP RANSAC
    cv::Mat rvec, tvec, inliers;
    const bool pnp_success = cv::solvePnPRansac(obj_pts, img_pts, camera_mat, cv::noArray(),
                        rvec, tvec, false,
                        kPnpIterations, kPnpReprojError,
                        kPnpConfidence, inliers);

    int inlier_count = inliers.rows;
    match_trace.pnp_success = pnp_success;
    match_trace.pnp_inliers = inlier_count;
    match_trace.inlier_ratio = static_cast<double>(inlier_count) / good_matches.size();
    if (match_trace.enabled()) {
        match_trace.inlier_indices = "[";
        for (int i = 0; i < inliers.rows; ++i) {
            if (i) match_trace.inlier_indices += ',';
            match_trace.inlier_indices += std::to_string(inliers.at<int>(i, 0));
        }
        match_trace.inlier_indices += ']';
        const auto vector_json = [](const cv::Mat& value) {
            std::string json = "[";
            for (std::size_t i = 0; i < value.total(); ++i) {
                if (i) json += ',';
                json += vl_diagnostic::number(value.depth() == CV_64F ? value.ptr<double>()[i] : value.ptr<float>()[i]);
            }
            return json + ']';
        };
        if (!rvec.empty()) match_trace.rvec = vector_json(rvec);
        if (!tvec.empty()) match_trace.tvec = vector_json(tvec);
        if (pnp_success && !inliers.empty() && !rvec.empty() && !tvec.empty()) {
            const auto metric = reprojectionMetric(obj_pts, img_pts, rvec, tvec, camera_mat, inliers);
            if (metric.valid) match_trace.ransac_rmse = metric.rmse_px;
        }
    }
    if (!pnp_success || inlier_count < kMinInlierCount) {
        match_trace.reason = pnp_success ? "insufficient_pnp_inliers" : "pnp_failed";
        return lost;
    }

    if (!final_geometry::validInlierIndices(inliers, obj_pts.size())) {
        match_trace.reason = "invalid_pnp_inlier_indices";
        return lost;
    }

    // Inlier ratio quality gate (kMinInlierRatio = 0.15)
    int good_count = static_cast<int>(good_matches.size());
    if (good_count > 0) {
        float inlier_ratio = static_cast<float>(inlier_count) / static_cast<float>(good_count);
        if (inlier_ratio < kMinInlierRatio) {
            match_trace.reason = "insufficient_pnp_inlier_ratio";
            return lost;
        }
    }

    // PnP Refinement: 用 RANSAC inlier 做 iterative 精化
    {
        std::vector<cv::Point3f> inlier_obj;
        std::vector<cv::Point2f> inlier_img;
        inlier_obj.reserve(inlier_count);
        inlier_img.reserve(inlier_count);
        for (int i = 0; i < inliers.rows; i++) {
            int idx = inliers.at<int>(i, 0);
            inlier_obj.push_back(obj_pts[idx]);
            inlier_img.push_back(img_pts[idx]);
        }
        cv::Mat rvec_ref = rvec.clone(), tvec_ref = tvec.clone();
        bool ok = cv::solvePnP(inlier_obj, inlier_img, camera_mat, cv::noArray(),
                                rvec_ref, tvec_ref, true, cv::SOLVEPNP_ITERATIVE);
        match_trace.refinement_success = ok;
        if (ok) {
            rvec = rvec_ref;
            tvec = tvec_ref;
        }
        // 精化失败则保留 RANSAC 原始结果
    }

    const auto final = final_geometry::validatePnP(pnp_success, obj_pts, img_pts,
        camera_mat, rvec, tvec, inliers, kPnpReprojError);
    traceFinalGeometry(diagnostic_trace_,"AKAZE",diagnostic_kf_id,final,tvec,inliers.rows);
    if (!final.accepted) {
        match_trace.reason = final.reason;
        return lost;
    }

    if (out_metric || match_trace.enabled()) {
        const auto metric = reprojectionMetric(obj_pts, img_pts, rvec, tvec, camera_mat, inliers);
        if (out_metric) *out_metric = metric;
        if (metric.valid) match_trace.refined_rmse = metric.rmse_px;
    }

    // Compose T_C_S with the same single normalization as ORB matching.
    const cv::Mat& rot_mat = final.rotation;

    VLResult result;
    result.state = 1; // TRACKING
    result.confidence = std::min(1.0f,
        static_cast<float>(inlier_count) / kMaxConfidenceDivisor);
    result.matched_features = inlier_count;

    // Fill T_C_S once as row-major after exactly one normalization.
    const cv::Mat camera_from_scan =
        visual_localizer::pose_contract::cameraFromScanFromOpenCvPnP(rot_mat, tvec);
    std::memcpy(result.pose, camera_from_scan.ptr<float>(), 16 * sizeof(float));

    match_trace.reason = "accepted";
    if (match_trace.enabled()) match_trace.pose = vl_diagnostic::array(result.pose, 16);
    return result;
}

// Data candidate: jointly verify already-computed cross-checked matches.
// It changes neither future tracking state nor matching/PnP thresholds.
VLResult VisualLocalizer::tryJointPool(const std::vector<joint_pool::Observation>& observations,
    int width,int height,float fx,float fy,float cx,float cy,
    const char* path,int raw_count,ReprojectionMetric* out_metric) {
    auto lost=makeLostResult(); if(out_metric)*out_metric={};
    if(raw_count>4096) {
        if(diagnostic_trace_ && diagnostic_trace_->enabled()) diagnostic_trace_->emit("pool_capacity_rejected",
            "\"path\":\""+std::string(path)+"\",\"input_count\":"+std::to_string(raw_count)+",\"capacity\":4096");
        return lost;
    }
    const auto prepare_start=vl_diagnostic::Clock::now();
    const auto pool=joint_pool::consolidate(observations);
    std::vector<cv::Point3f> object;
    std::vector<cv::Point2f> image;
    std::set<int> keyframes;
    for(const auto& p:pool.points) {object.push_back(p.object);image.push_back(p.image);keyframes.insert(p.keyframe_id);}
    if(diagnostic_trace_ && diagnostic_trace_->enabled()) {
        std::string points="[",raw="[";
        const auto point_json=[](const joint_pool::Observation& p) {
            const float values[]={p.image.x,p.image.y,p.object.x,p.object.y,p.object.z,p.distance};
            return "{\"query_index\":"+std::to_string(p.query_index)+",\"kf_id\":"+std::to_string(p.keyframe_id)+
                ",\"train_index\":"+std::to_string(p.train_index)+",\"uv_xyz_distance\":"+vl_diagnostic::array(values,6)+"}";
        };
        for(const auto& p:pool.points) {if(points.size()>1)points+=',';points+=point_json(p);}points+=']';
        for(const auto& p:observations) {if(raw.size()>1)raw+=',';raw+=point_json(p);}raw+=']';
        diagnostic_trace_->emit("pool_prepared","\"path\":\""+std::string(path)+"\",\"input_count\":"+std::to_string(pool.input_count)+
            ",\"query_groups\":"+std::to_string(pool.query_groups)+",\"conflict_groups\":"+std::to_string(pool.conflict_groups)+
            ",\"object_conflict_groups\":"+std::to_string(pool.object_conflict_groups)+",\"unique_count\":"+std::to_string(pool.points.size())+
            ",\"keyframe_count\":"+std::to_string(keyframes.size())+",\"points\":"+points+",\"raw_observations\":"+raw+
            ",\"elapsed_ms\":"+vl_diagnostic::number(vl_diagnostic::elapsedMs(prepare_start)));
    }
    vl_diagnostic::MatchTrace trace(diagnostic_trace_,path,-2);
    trace.raw=pool.input_count;trace.cross_checked=trace.valid_3d=static_cast<int>(object.size());
    if(object.size()<kMinGoodMatches) {trace.reason="insufficient_unique_pool_matches";return lost;}
    if(keyframes.size()<2) {trace.reason="single_keyframe_pool";return lost;}
    if(!joint_pool::spatiallyDistributed(image,width,height)) {trace.reason="insufficient_pool_spatial_distribution";return lost;}
    cv::Mat camera=(cv::Mat_<double>(3,3)<<double(fx),0,double(cx),0,double(fy),double(cy),0,0,1);
    cv::Mat rvec,tvec,inliers;
    const auto pnp_start=vl_diagnostic::Clock::now();
    bool ok=cv::solvePnPRansac(object,image,camera,cv::noArray(),rvec,tvec,false,
        kPnpIterations,kPnpReprojError,kPnpConfidence,inliers);
    trace.pnp_success=ok;trace.pnp_inliers=inliers.rows;trace.inlier_ratio=double(inliers.rows)/object.size();
    if(trace.enabled()) {
        trace.inlier_indices="[";for(int i=0;i<inliers.rows;++i) {if(i)trace.inlier_indices+=',';trace.inlier_indices+=std::to_string(inliers.at<int>(i,0));}trace.inlier_indices+=']';
        diagnostic_trace_->emit("pool_pnp_cost","\"path\":\""+std::string(path)+"\",\"elapsed_ms\":"+vl_diagnostic::number(vl_diagnostic::elapsedMs(pnp_start)));
    }
    if(!ok || inliers.rows<kMinInlierCount) {trace.reason=ok?"insufficient_pnp_inliers":"pnp_failed";return lost;}
    if(!final_geometry::validInlierIndices(inliers,object.size())) {trace.reason="invalid_pnp_inlier_indices";return lost;}
    if(trace.inlier_ratio<kMinInlierRatio) {trace.reason="insufficient_pnp_inlier_ratio";return lost;}
    std::vector<cv::Point3f> inlier_object;
    std::vector<cv::Point2f> inlier_image;
    std::set<int> inlier_keyframes;
    for(int i=0;i<inliers.rows;++i) {
        int index=inliers.at<int>(i,0);inlier_object.push_back(object[index]);inlier_image.push_back(image[index]);
        inlier_keyframes.insert(pool.points[index].keyframe_id);
    }
    if(inlier_keyframes.size()<2 || !joint_pool::spatiallyDistributed(inlier_image,width,height)) {
        trace.reason="insufficient_inlier_spatial_distribution";return lost;
    }
    cv::Mat centered(static_cast<int>(inlier_object.size()),3,CV_64F);
    cv::Point3d mean;for(const auto& p:inlier_object)mean+=cv::Point3d(p);mean*=1.0/inlier_object.size();
    for(int i=0;i<centered.rows;++i) {centered.at<double>(i,0)=inlier_object[i].x-mean.x;centered.at<double>(i,1)=inlier_object[i].y-mean.y;centered.at<double>(i,2)=inlier_object[i].z-mean.z;}
    cv::Mat singular;cv::SVD::compute(centered,singular);
    const double planar_ratio=singular.at<double>(0)>0?singular.at<double>(2)/singular.at<double>(0):0;
    auto rref=rvec.clone(),tref=tvec.clone();
    const auto refine_start=vl_diagnostic::Clock::now();
    bool refined=cv::solvePnP(inlier_object,inlier_image,camera,cv::noArray(),rref,tref,true,cv::SOLVEPNP_ITERATIVE);
    trace.refinement_success=refined;
    if(refined) {rvec=rref;tvec=tref;}
    const auto final=final_geometry::validatePnP(ok,object,image,camera,rvec,tvec,inliers,kPnpReprojError);
    traceFinalGeometry(diagnostic_trace_,path,-2,final,tvec,inliers.rows);
    trace.refined_rmse=final.rmse;
    if(trace.enabled()) diagnostic_trace_->emit("pool_geometry","\"path\":\""+std::string(path)+
        "\",\"planarity_s3_s1\":"+vl_diagnostic::number(planar_ratio)+",\"planarity_warning\":"+vl_diagnostic::boolean(planar_ratio<.01)+
        ",\"max_reprojection_original_px\":"+vl_diagnostic::number(final.maximum_error)+",\"minimum_depth_m\":"+vl_diagnostic::number(final.minimum_depth)+
        ",\"elapsed_ms\":"+vl_diagnostic::number(vl_diagnostic::elapsedMs(refine_start)));
    if(!final.accepted) {trace.reason=final.reason;return lost;}
    const cv::Mat& rotation=final.rotation;
    const auto pose=visual_localizer::pose_contract::cameraFromScanFromOpenCvPnP(rotation,tvec);
    if(!cv::checkRange(pose) || std::abs(cv::determinant(rotation)-1)>1e-4) {trace.reason="invalid_rigid_pose";return lost;}
    VLResult result;result.state=1;result.matched_features=inliers.rows;
    result.confidence=std::min(1.f,float(inliers.rows)/kMaxConfidenceDivisor);
    std::memcpy(result.pose,pose.ptr<float>(),sizeof(result.pose));
    last_debug_info_.best_kf_id=-2;last_debug_info_.candidate_keyframes=static_cast<int>(keyframes.size());
    last_debug_info_.best_raw_matches=pool.input_count;last_debug_info_.best_good_matches=static_cast<int>(object.size());
    last_debug_info_.best_inliers=inliers.rows;last_debug_info_.best_inlier_ratio=float(trace.inlier_ratio);
    if(std::strncmp(path,"AKAZE",5)==0) {last_debug_info_.akaze_triggered=1;last_debug_info_.akaze_best_inliers=inliers.rows;}
    if(out_metric) {out_metric->valid=true;out_metric->rmse_px=float(trace.refined_rmse);}
    trace.reason="accepted";if(trace.enabled())trace.pose=vl_diagnostic::array(result.pose,16);
    return result;
}

// ---------------------------------------------------------------------------
// computeBoW — for each descriptor, find nearest vocab word, accumulate IDF,
//              then L2-normalize the resulting vector
// ---------------------------------------------------------------------------
std::vector<float> VisualLocalizer::computeBoW(const cv::Mat& descriptors) {
    auto* trace = diagnostic_trace_;
    const bool trace_enabled = trace && trace->enabled();
    const auto bow_start = trace_enabled ? vl_diagnostic::Clock::now()
                                        : vl_diagnostic::Clock::time_point{};
    int vocab_size = static_cast<int>(vocabulary_.size());
    const auto emit_bow_cost = [&]() {
        if (trace_enabled) trace->emit("bow_cost",
            "\"desc_rows\":" + std::to_string(descriptors.rows) +
            ",\"vocab_count\":" + std::to_string(vocab_size) +
            ",\"elapsed_ms\":" + vl_diagnostic::number(vl_diagnostic::elapsedMs(bow_start)));
    };
    if (vocab_size == 0) {
        emit_bow_cost();
        return {};
    }

    std::vector<float> bow(vocab_size, 0.0f);

    for (int i = 0; i < descriptors.rows; i++) {
        const unsigned char* desc = descriptors.ptr<unsigned char>(i);
        int best_word = 0;
        int best_dist = INT_MAX;

        for (int w = 0; w < vocab_size; w++) {
            int len = std::min(32,
                static_cast<int>(vocabulary_[w].descriptor.size()));
            int dist = hammingDistance(desc, vocabulary_[w].descriptor.data(),
                                       len);
            if (dist < best_dist) {
                best_dist = dist;
                best_word = w;
            }
        }
        bow[best_word] += vocabulary_[best_word].idf_weight;
    }

    // L2 normalize
    float norm = 0.0f;
    for (float v : bow)
        norm += v * v;
    norm = std::sqrt(norm);
    if (norm > 1e-9f) {
        for (float& v : bow)
            v /= norm;
    }

    emit_bow_cost();
    return bow;
}

// ---------------------------------------------------------------------------
// getNearbyKeyframes — filter keyframes within Euclidean radius of last pose,
//                      sorted by distance, return top max_count
// ---------------------------------------------------------------------------
std::vector<KeyframeData*> VisualLocalizer::getNearbyKeyframes(
    const float* scan_from_camera_4x4, float radius, int max_count) {

    // Extract camera position from T_S_C row-major elements [3], [7], [11].
    float lx = scan_from_camera_4x4[3];
    float ly = scan_from_camera_4x4[7];
    float lz = scan_from_camera_4x4[11];

    struct Candidate {
        KeyframeData* kf;
        float dist;
    };
    std::vector<Candidate> within_radius;

    for (auto& kf : keyframes_) {
        // Extract keyframe translation from its 4x4 pose
        float kx = kf.pose.at<float>(0, 3);
        float ky = kf.pose.at<float>(1, 3);
        float kz = kf.pose.at<float>(2, 3);

        float dx = lx - kx;
        float dy = ly - ky;
        float dz = lz - kz;
        float dist = std::sqrt(dx * dx + dy * dy + dz * dz);

        if (dist <= radius) {
            within_radius.push_back({&kf, dist});
        }
    }

    // Sort by distance ascending
    std::sort(within_radius.begin(), within_radius.end(),
              [](const Candidate& a, const Candidate& b) {
                  return a.dist < b.dist;
              });

    if (diagnostic_trace_ && diagnostic_trace_->enabled()) {
        std::string ranked = "[";
        for (std::size_t i = 0; i < within_radius.size(); ++i) {
            if (i) ranked += ',';
            ranked += "{\"kf_id\":" + std::to_string(within_radius[i].kf->id) + ",\"rank\":" + std::to_string(i + 1) +
                ",\"distance_m\":" + vl_diagnostic::number(within_radius[i].dist) +
                ",\"selected\":" + vl_diagnostic::boolean(i < static_cast<std::size_t>(max_count)) + "}";
        }
        diagnostic_trace_->emit("retrieval", "\"source\":\"nearby\",\"ranked_candidates\":" + ranked + "]");
    }

    // Return top max_count
    std::vector<KeyframeData*> result;
    int count = std::min(max_count, static_cast<int>(within_radius.size()));
    result.reserve(count);
    for (int i = 0; i < count; i++) {
        result.push_back(within_radius[i].kf);
    }

    return result;
}

// ---------------------------------------------------------------------------
// getGlobalCandidates — compute BoW similarity, return top-K keyframes
// ---------------------------------------------------------------------------
std::vector<KeyframeData*> VisualLocalizer::getGlobalCandidates(
    const cv::Mat& descriptors) {

    std::vector<float> query_bow = computeBoW(descriptors);
    if (query_bow.empty())
        return {};

    struct Candidate {
        KeyframeData* kf;
        float similarity;
    };
    std::vector<Candidate> scored;
    scored.reserve(keyframes_.size());

    for (auto& kf : keyframes_) {
        float sim = cosineSimilarity(query_bow, kf.global_descriptor);
        scored.push_back({&kf, sim});
    }

    // Sort by similarity descending
    std::sort(scored.begin(), scored.end(),
              [](const Candidate& a, const Candidate& b) {
                  return a.similarity > b.similarity;
              });

    if (diagnostic_trace_ && diagnostic_trace_->enabled()) {
        std::string ranked = "[";
        for (std::size_t i = 0; i < scored.size(); ++i) {
            if (i) ranked += ',';
            ranked += "{\"kf_id\":" + std::to_string(scored[i].kf->id) + ",\"rank\":" + std::to_string(i + 1) +
                ",\"bow_similarity\":" + vl_diagnostic::number(scored[i].similarity) +
                ",\"selected\":" + vl_diagnostic::boolean(i < kGlobalTopK && scored[i].similarity >= kMinBoWSimilarity) + "}";
        }
        diagnostic_trace_->emit("retrieval", "\"source\":\"global_bow\",\"ranked_candidates\":" + ranked + "]");
    }

    // Filter out candidates below minimum BoW similarity threshold
    while (!scored.empty() && scored.back().similarity < kMinBoWSimilarity) {
        scored.pop_back();
    }

    // Return top-K
    std::vector<KeyframeData*> result;
    int count = std::min(kGlobalTopK, static_cast<int>(scored.size()));
    result.reserve(count);
    for (int i = 0; i < count; i++) {
        result.push_back(scored[i].kf);
    }

    // Record best BoW similarity for debug
    if (!scored.empty()) {
        last_debug_info_.best_bow_sim = scored[0].similarity;
    }

    return result;
}

// ---------------------------------------------------------------------------
// hammingDistance — compare two unsigned char descriptor byte arrays via
//                  XOR + popcount (Brian Kernighan's method).
//                  Both vocabulary and query descriptors are now uint8.
// ---------------------------------------------------------------------------
int VisualLocalizer::hammingDistance(const unsigned char* a, const unsigned char* b,
                                     int len) {
    if (len <= 0) return 0;
    int dist = 0;
#if defined(__clang__) || defined(__GNUC__)
    constexpr int word_bytes = static_cast<int>(sizeof(std::uint64_t));
    int i = 0;
    for (; i <= len - word_bytes; i += word_bytes) {
        std::uint64_t first, second;
        std::memcpy(&first, a + i, sizeof(first));
        std::memcpy(&second, b + i, sizeof(second));
        dist += __builtin_popcountll(static_cast<unsigned long long>(first ^ second));
    }
    for (; i < len; ++i) {
        dist += __builtin_popcount(static_cast<unsigned int>(a[i] ^ b[i]));
    }
#else
    for (int i = 0; i < len; i++) {
        unsigned char xor_val = a[i] ^ b[i];
        // Brian Kernighan's popcount
        while (xor_val != 0) {
            dist++;
            xor_val &= static_cast<unsigned char>(xor_val - 1);
        }
    }
#endif
    return dist;
}

// ---------------------------------------------------------------------------
// cosineSimilarity — dot product of two L2-normalized vectors
// ---------------------------------------------------------------------------
float VisualLocalizer::cosineSimilarity(const std::vector<float>& a,
                                         const std::vector<float>& b) {
    if (a.size() != b.size() || a.empty())
        return 0.0f;

    float dot = 0.0f;
    float norm_a = 0.0f;
    float norm_b = 0.0f;
    for (size_t i = 0; i < a.size(); i++) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    float denom = std::sqrt(norm_a) * std::sqrt(norm_b);
    if (denom < 1e-9f)
        return 0.0f;

    return dot / denom;
}
