#include "visual_localizer_impl.h"
#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <climits>
#include <numeric>
#include <unordered_map>

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

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------
VisualLocalizer::VisualLocalizer()
    : orb_(cv::ORB::create(kOrbNFeatures))
    , matcher_(cv::BFMatcher::create(cv::NORM_HAMMING))
    , index_built_(false)
    , akaze_(cv::AKAZE::create())
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
}

// ---------------------------------------------------------------------------
// buildIndex — mark data loading complete
// ---------------------------------------------------------------------------
bool VisualLocalizer::buildIndex() {
    index_built_ = true;
    return true;
}

// ---------------------------------------------------------------------------
// reset — clear tracking state
// ---------------------------------------------------------------------------
void VisualLocalizer::reset() {
    frame_history_.clear();
}

// ---------------------------------------------------------------------------
// setAlignmentTransform — set pre-computed 4×4 alignment transform (AT)
//   Validates: no NaN, approximately rigid body (R^T*R ≈ I, det(R) ≈ +1)
//   Invalid input is silently ignored (previous state preserved)
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

    // Valid rigid body transform — store it
    alignment_transform_ = at.clone();
    has_alignment_transform_ = true;
}

// ---------------------------------------------------------------------------
// processFrame — full localization pipeline for a single grayscale frame
// ---------------------------------------------------------------------------
VLResult VisualLocalizer::processFrame(const unsigned char* image_data,
                                        int width, int height,
                                        float fx, float fy, float cx, float cy,
                                        bool has_last_pose,
                                        const float* last_pose_4x4) {
    VLResult lost = makeLostResult();

    // Reset debug info
    last_debug_info_ = {};
    last_debug_info_.best_kf_id = -1;

    if (!image_data || width <= 0 || height <= 0)
        return lost;

    // Step 1: Wrap image data as cv::Mat (zero-copy)
    cv::Mat gray(height, width, CV_8UC1,
                 const_cast<unsigned char*>(image_data));

    // Step 1.5: CLAHE preprocessing — reduce cross-session lighting differences
    cv::Mat enhanced;
    auto clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    clahe->apply(gray, enhanced);

    // Step 2: ORB detect + compute
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    orb_->detectAndCompute(enhanced, cv::noArray(), keypoints, descriptors);

    last_debug_info_.orb_keypoints = static_cast<int>(keypoints.size());

    if (static_cast<int>(keypoints.size()) < kMinFeatureCount || descriptors.empty())
        return lost;

    // Step 3: Candidate keyframe selection
    std::vector<KeyframeData*> candidates;
    if (has_last_pose && last_pose_4x4) {
        candidates = getNearbyKeyframes(last_pose_4x4, kNearbyRadius,
                                         kMaxNearbyKeyframes);
        if (candidates.empty())
            candidates = getGlobalCandidates(descriptors);
    } else {
        candidates = getGlobalCandidates(descriptors);
    }

    last_debug_info_.candidate_keyframes = static_cast<int>(candidates.size());

    if (candidates.empty())
        return lost;

    // Step 4: Try matching each candidate, keep best by inlier count
    VLResult best = lost;
    int best_inliers = 0;
    int best_raw = 0, best_good = 0;

    for (auto* kf : candidates) {
        int raw_matches = 0, good_matches_count = 0;
        VLResult result = tryMatchKeyframe(*kf, keypoints, descriptors,
                                            fx, fy, cx, cy,
                                            &raw_matches, &good_matches_count);
        if (raw_matches > best_raw) best_raw = raw_matches;
        if (good_matches_count > best_good) {
            best_good = good_matches_count;
        }
        if (result.state == 1 && result.matched_features > best_inliers) {
            best = result;
            best_inliers = result.matched_features;
            last_debug_info_.best_kf_id = kf->id;
        }
    }

    last_debug_info_.best_raw_matches = best_raw;
    last_debug_info_.best_good_matches = best_good;
    last_debug_info_.best_inliers = best_inliers;
    last_debug_info_.best_inlier_ratio = (best_good > 0)
        ? static_cast<float>(best_inliers) / static_cast<float>(best_good)
        : 0.0f;

    // -----------------------------------------------------------------------
    // AKAZE Fallback: ORB 全部失败 且 akaze_keyframes_ 非空时触发
    // -----------------------------------------------------------------------
    if (best.state != 1 && !akaze_keyframes_.empty()) {
        last_debug_info_.akaze_triggered = 1;
        VLResult akaze_result = tryAkazeFallback(enhanced, candidates,
                                                  fx, fy, cx, cy);
        if (akaze_result.state == 1) {
            best = akaze_result;
            best_inliers = akaze_result.matched_features;
            last_debug_info_.akaze_best_inliers = akaze_result.matched_features;
        }
    }

    // -----------------------------------------------------------------------
    // 多帧一致性过滤: 用 s2a_err 的 median + 3×MAD 阈值剔除离群帧
    // -----------------------------------------------------------------------
    if (best.state == 1 && has_last_pose && last_pose_4x4) {
        // 构建 w2c (4×4) from best.pose (row-major float[16])
        cv::Mat w2c(4, 4, CV_32F);
        std::memcpy(w2c.data, best.pose, 16 * sizeof(float));

        // 构建 c2w from last_pose_4x4 (AR camera pose, row-major)
        cv::Mat c2w(4, 4, CV_32F);
        std::memcpy(c2w.data, last_pose_4x4, 16 * sizeof(float));

        // s2a = c2w × w2c
        cv::Mat s2a = c2w * w2c;

        // s2a_err = ‖s2a − I‖_F
        cv::Mat identity = cv::Mat::eye(4, 4, CV_32F);
        cv::Mat diff = s2a - identity;
        float s2a_err = static_cast<float>(cv::norm(diff, cv::NORM_L2));

        if (static_cast<int>(frame_history_.size()) < 3) {
            // 冷启动: 跳过过滤，直接接受
            FrameHistory fh;
            fh.pose = w2c.clone();
            fh.s2a = s2a.clone();
            fh.s2a_err = s2a_err;
            frame_history_.push_back(std::move(fh));
            if (static_cast<int>(frame_history_.size()) > kMaxHistoryFrames) {
                frame_history_.pop_front();
            }
        } else {
            // 收集历史帧 s2a_err
            std::vector<float> hist_errs;
            hist_errs.reserve(frame_history_.size());
            for (const auto& fh : frame_history_) {
                hist_errs.push_back(fh.s2a_err);
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

            if (s2a_err > threshold) {
                // 离群帧: 拒绝，返回 LOST
                last_debug_info_.consistency_rejected = 1;
                return lost;
            }

            // 通过一致性检查: 加入历史队列
            FrameHistory fh;
            fh.pose = w2c.clone();
            fh.s2a = s2a.clone();
            fh.s2a_err = s2a_err;
            frame_history_.push_back(std::move(fh));
            if (static_cast<int>(frame_history_.size()) > kMaxHistoryFrames) {
                frame_history_.pop_front();
            }
        }
    } else if (best.state == 1) {
        // 有效定位但无 AR camera pose: 无法计算 s2a，跳过一致性过滤
        // 仍然将 w2c 存入历史（s2a 和 s2a_err 留空）
    }

    // -----------------------------------------------------------------------
    // 坐标系对齐变换: AT 已设置时 pose_aligned = AT × pose_raw
    // -----------------------------------------------------------------------
    if (best.state == 1 && has_alignment_transform_) {
        cv::Mat pose_raw(4, 4, CV_32F);
        std::memcpy(pose_raw.data, best.pose, 16 * sizeof(float));

        cv::Mat pose_aligned = alignment_transform_ * pose_raw;

        std::memcpy(best.pose, pose_aligned.data, 16 * sizeof(float));
    }

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
                                            int* out_good_matches) {
    VLResult lost = makeLostResult();
    if (out_raw_matches) *out_raw_matches = 0;
    if (out_good_matches) *out_good_matches = 0;

    if (kf.descriptors.empty())
        return lost;

    // KNN match (k=2)
    std::vector<std::vector<cv::DMatch>> knn_matches;
    matcher_->knnMatch(query_desc, kf.descriptors, knn_matches, 2);

    if (out_raw_matches) *out_raw_matches = static_cast<int>(knn_matches.size());

    // Lowe ratio test
    std::vector<cv::DMatch> good_matches;
    for (const auto& m : knn_matches) {
        if (m.size() >= 2 &&
            m[0].distance < kLoweRatio * m[1].distance) {
            good_matches.push_back(m[0]);
        }
    }

    // Fallback: if Lowe ratio yields too few matches, use absolute distance threshold
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        good_matches.clear();
        for (const auto& m : knn_matches) {
            if (!m.empty() && m[0].distance < kAbsoluteDistThreshold) {
                good_matches.push_back(m[0]);
            }
        }
    }

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

    if (static_cast<int>(good_matches.size()) < kMinGoodMatches)
        return lost;

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
        }
    }

    if (static_cast<int>(obj_pts.size()) < kMinGoodMatches)
        return lost;

    // Camera intrinsic matrix
    cv::Mat camera_mat = (cv::Mat_<double>(3, 3) <<
        static_cast<double>(fx), 0.0, static_cast<double>(cx),
        0.0, static_cast<double>(fy), static_cast<double>(cy),
        0.0, 0.0, 1.0);

    // PnP RANSAC
    cv::Mat rvec, tvec, inliers;
    cv::solvePnPRansac(obj_pts, img_pts, camera_mat, cv::noArray(),
                        rvec, tvec, false,
                        kPnpIterations, kPnpReprojError,
                        kPnpConfidence, inliers);

    int inlier_count = inliers.rows;
    if (inlier_count < kMinInlierCount)
        return lost;

    // Inlier ratio quality gate: reject if too few inliers relative to matches
    int good_count = static_cast<int>(good_matches.size());
    if (good_count > 0) {
        float inlier_ratio = static_cast<float>(inlier_count) / static_cast<float>(good_count);
        if (inlier_ratio < kMinInlierRatio)
            return lost;
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
        if (ok) {
            rvec = rvec_ref;
            tvec = tvec_ref;
        }
        // 精化失败则保留 RANSAC 原始结果
    }

    // Compose pose matrix from rvec/tvec via Rodrigues
    // solvePnPRansac returns world-to-camera extrinsic [R|t] in OpenCV
    // camera convention (x-right, y-down, z-forward).
    // Unity/ARKit uses (x-right, y-up, z-back).
    //
    // The 3D points fed to PnP are already in ARKit world coordinates (Y-up),
    // so PnP output [R|t] maps ARKit-world → OpenCV-camera.
    // The relationship is: R_opencv = flip * R_arkit_w2c, where flip = diag(1,-1,-1).
    // Therefore: R_arkit_w2c = flip * R_opencv  (left-multiply only).
    // Translation: t_arkit = flip * t_opencv.
    //
    // IMPORTANT: Do NOT right-multiply by flip — the world coordinates are
    // already in ARKit convention and must not be flipped.
    cv::Mat rot_mat;
    cv::Rodrigues(rvec, rot_mat);

    VLResult result;
    result.state = 1; // TRACKING
    result.confidence = std::min(1.0f,
        static_cast<float>(inlier_count) / kMaxConfidenceDivisor);
    result.matched_features = inlier_count;

    // Fill row-major 4x4 pose: R' = flip * R_opencv, t' = flip * t_opencv
    float R_raw[3][3];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            R_raw[r][c] = static_cast<float>(rot_mat.at<double>(r, c));

    float t_raw[3];
    for (int r = 0; r < 3; r++)
        t_raw[r] = static_cast<float>(tvec.at<double>(r, 0));

    // Apply flip = diag(1,-1,-1) on the LEFT only: R' = flip * R, t' = flip * t
    float flip[3] = {1.0f, -1.0f, -1.0f};
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++)
            result.pose[r * 4 + c] = flip[r] * R_raw[r][c];
        result.pose[r * 4 + 3] = flip[r] * t_raw[r];
    }
    result.pose[12] = 0.0f;
    result.pose[13] = 0.0f;
    result.pose[14] = 0.0f;
    result.pose[15] = 1.0f;

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
}

// ---------------------------------------------------------------------------
// tryAkazeFallback — AKAZE detectAndCompute on enhanced image, then try
//                    matching against candidates that have AKAZE data.
//                    Returns best result by inlier count, or LOST.
// ---------------------------------------------------------------------------
VLResult VisualLocalizer::tryAkazeFallback(const cv::Mat& enhanced,
                                            const std::vector<KeyframeData*>& candidates,
                                            float fx, float fy,
                                            float cx, float cy) {
    VLResult lost = makeLostResult();

    // 无 AKAZE 数据时不触发 fallback
    if (akaze_keyframes_.empty())
        return lost;

    // AKAZE 特征提取
    std::vector<cv::KeyPoint> akaze_kps;
    cv::Mat akaze_desc;
    akaze_->detectAndCompute(enhanced, cv::noArray(), akaze_kps, akaze_desc);

    if (akaze_kps.empty() || akaze_desc.empty())
        return lost;

    // 记录 AKAZE 特征点数到 debug info
    last_debug_info_.akaze_keypoints = static_cast<int>(akaze_kps.size());

    // 遍历候选 KF，仅对有 AKAZE 数据的 KF 进行匹配
    VLResult best = lost;
    int best_inliers = 0;

    for (auto* kf : candidates) {
        auto it = akaze_keyframes_.find(kf->id);
        if (it == akaze_keyframes_.end())
            continue;  // 无 AKAZE 数据的 KF 跳过

        int raw = 0, good = 0;
        VLResult result = tryMatchKeyframeAkaze(it->second, akaze_kps, akaze_desc,
                                                 fx, fy, cx, cy,
                                                 &raw, &good);
        if (result.state == 1 && result.matched_features > best_inliers) {
            best = result;
            best_inliers = result.matched_features;
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
    int* out_raw, int* out_good) {

    VLResult lost = makeLostResult();
    if (out_raw) *out_raw = 0;
    if (out_good) *out_good = 0;

    if (akaze_kf.descriptors.empty())
        return lost;

    // KNN match (k=2) using AKAZE matcher (NORM_HAMMING)
    std::vector<std::vector<cv::DMatch>> knn_matches;
    akaze_matcher_->knnMatch(query_desc, akaze_kf.descriptors, knn_matches, 2);

    if (out_raw) *out_raw = static_cast<int>(knn_matches.size());

    // Lowe ratio test
    std::vector<cv::DMatch> good_matches;
    for (const auto& m : knn_matches) {
        if (m.size() >= 2 &&
            m[0].distance < kLoweRatio * m[1].distance) {
            good_matches.push_back(m[0]);
        }
    }

    // Fallback: absolute distance threshold (same as ORB path)
    if (static_cast<int>(good_matches.size()) < kMinGoodMatches) {
        good_matches.clear();
        for (const auto& m : knn_matches) {
            if (!m.empty() && m[0].distance < kAbsoluteDistThreshold) {
                good_matches.push_back(m[0]);
            }
        }
    }

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

    if (static_cast<int>(good_matches.size()) < kMinGoodMatches)
        return lost;

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
        }
    }

    if (static_cast<int>(obj_pts.size()) < kMinGoodMatches)
        return lost;

    // Camera intrinsic matrix
    cv::Mat camera_mat = (cv::Mat_<double>(3, 3) <<
        static_cast<double>(fx), 0.0, static_cast<double>(cx),
        0.0, static_cast<double>(fy), static_cast<double>(cy),
        0.0, 0.0, 1.0);

    // PnP RANSAC
    cv::Mat rvec, tvec, inliers;
    cv::solvePnPRansac(obj_pts, img_pts, camera_mat, cv::noArray(),
                        rvec, tvec, false,
                        kPnpIterations, kPnpReprojError,
                        kPnpConfidence, inliers);

    int inlier_count = inliers.rows;
    if (inlier_count < kMinInlierCount)
        return lost;

    // Inlier ratio quality gate (kMinInlierRatio = 0.15)
    int good_count = static_cast<int>(good_matches.size());
    if (good_count > 0) {
        float inlier_ratio = static_cast<float>(inlier_count) / static_cast<float>(good_count);
        if (inlier_ratio < kMinInlierRatio)
            return lost;
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
        if (ok) {
            rvec = rvec_ref;
            tvec = tvec_ref;
        }
        // 精化失败则保留 RANSAC 原始结果
    }

    // Compose pose matrix from rvec/tvec (same convention as tryMatchKeyframe)
    cv::Mat rot_mat;
    cv::Rodrigues(rvec, rot_mat);

    VLResult result;
    result.state = 1; // TRACKING
    result.confidence = std::min(1.0f,
        static_cast<float>(inlier_count) / kMaxConfidenceDivisor);
    result.matched_features = inlier_count;

    // Fill row-major 4x4 pose: R' = flip * R_opencv, t' = flip * t_opencv
    float R_raw[3][3];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            R_raw[r][c] = static_cast<float>(rot_mat.at<double>(r, c));

    float t_raw[3];
    for (int r = 0; r < 3; r++)
        t_raw[r] = static_cast<float>(tvec.at<double>(r, 0));

    // Apply flip = diag(1,-1,-1) on the LEFT only
    float flip[3] = {1.0f, -1.0f, -1.0f};
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++)
            result.pose[r * 4 + c] = flip[r] * R_raw[r][c];
        result.pose[r * 4 + 3] = flip[r] * t_raw[r];
    }
    result.pose[12] = 0.0f;
    result.pose[13] = 0.0f;
    result.pose[14] = 0.0f;
    result.pose[15] = 1.0f;

    return result;
}

// ---------------------------------------------------------------------------
// computeBoW — for each descriptor, find nearest vocab word, accumulate IDF,
//              then L2-normalize the resulting vector
// ---------------------------------------------------------------------------
std::vector<float> VisualLocalizer::computeBoW(const cv::Mat& descriptors) {
    int vocab_size = static_cast<int>(vocabulary_.size());
    if (vocab_size == 0)
        return {};

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

    return bow;
}

// ---------------------------------------------------------------------------
// getNearbyKeyframes — filter keyframes within Euclidean radius of last pose,
//                      sorted by distance, return top max_count
// ---------------------------------------------------------------------------
std::vector<KeyframeData*> VisualLocalizer::getNearbyKeyframes(
    const float* last_pose, float radius, int max_count) {

    // Extract translation from 4x4 row-major pose: elements [3], [7], [11]
    float lx = last_pose[3];
    float ly = last_pose[7];
    float lz = last_pose[11];

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
    int dist = 0;
    for (int i = 0; i < len; i++) {
        unsigned char xor_val = a[i] ^ b[i];
        // Brian Kernighan's popcount
        while (xor_val != 0) {
            dist++;
            xor_val &= static_cast<unsigned char>(xor_val - 1);
        }
    }
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
