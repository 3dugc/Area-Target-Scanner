#pragma once
#include <opencv2/core.hpp>
#if CV_VERSION_MAJOR >= 5
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#else
#include <opencv2/features2d.hpp>
#endif
#include <deque>
#include <unordered_map>
#include <vector>
#include "visual_localizer.h"
#include "diagnostic_trace.h"
#include "joint_pool.h"

#if CV_VERSION_MAJOR >= 5
using VisualLocalizerAkaze = cv::xfeatures2d::AKAZE;
#else
using VisualLocalizerAkaze = cv::AKAZE;
#endif

struct VocabWord {
    int word_id;
    std::vector<unsigned char> descriptor;
    float idf_weight;
};

struct KeyframeData {
    int id;
    cv::Mat pose;              // 4x4 float
    cv::Mat descriptors;       // Nx32 CV_8UC1
    std::vector<cv::Point3f> points3d;
    std::vector<cv::Point2f> points2d;
    std::vector<float> global_descriptor; // BoW vector
};
struct ReprojectionMetric {
    float rmse_px = 0.0f;
    bool valid = false;
};

class VisualLocalizer {
public:
    VisualLocalizer();
    ~VisualLocalizer();

    void addVocabularyWord(int word_id, const unsigned char* desc, int desc_len, float idf_weight);
    void addKeyframe(int kf_id, const float* pose_4x4,
                     const unsigned char* descriptors, int desc_count,
                     const float* points3d, const float* points2d);
    bool buildIndex();

    VLDebugInfo getDebugInfo() const { return last_debug_info_; }
    ReprojectionMetric getReprojectionMetric() const { return last_reprojection_metric_; }

    VLResult processFrame(const unsigned char* image_data, int width, int height,
                          float fx, float fy, float cx, float cy,
                          bool has_unity_world_from_camera,
                          const float* unity_world_from_camera_4x4);
    void reset();
    bool setRecoveryMode(int mode) {
        if (mode != 0 && mode != 1) return false;
        recovery_mode_ = mode;
        return true;
    }

    // Legacy ABI hook. It validates input but must not mutate T_C_S output.
    void setAlignmentTransform(const float* at_4x4);

    // AKAZE keyframe 数据加载: 每个 keyframe 的 AKAZE 描述子和对应 3D/2D 点
    void addKeyframeAkaze(int kf_id, const unsigned char* descriptors,
                          int desc_count, int desc_len,
                          const float* points3d, const float* points2d);

private:
    cv::Ptr<cv::ORB> orb_;
    cv::Ptr<cv::BFMatcher> matcher_;
    std::vector<VocabWord> vocabulary_;
    std::vector<KeyframeData> keyframes_;
    bool index_built_ = false;
    int recovery_mode_ = 0; // Per-handle choice; reset preserves it.

    // Debug diagnostics for last processed frame
    VLDebugInfo last_debug_info_ = {};
    ReprojectionMetric last_reprojection_metric_;
    std::uint64_t diagnostic_frame_ordinal_ = 0;
    vl_diagnostic::FrameTrace* diagnostic_trace_ = nullptr;

    // Algorithm parameters — balanced for real-world AR
    static constexpr int kOrbNFeatures = 3000;          // 2000→3000: 提取更多特征点，增加跨 session 匹配机会
    static constexpr int kMinFeatureCount = 8;          // 10→8: 降低最低特征点门槛
    static constexpr float kLoweRatio = 0.75f;          // 0.85→0.75: 收紧 ratio test，减少跨 session ambiguous matches
    static constexpr int kMinGoodMatches = 8;           // 10→8: 降低好匹配数门槛
    static constexpr int kPnpIterations = 300;          // 200→300: 更多 RANSAC 迭代，提高找到好解的概率
    static constexpr float kPnpReprojError = 12.0f;     // 10→12: 放宽重投影误差容忍度
    static constexpr double kPnpConfidence = 0.99;
    static constexpr int kMinInlierCount = 8;           // 10→8: 降低 inlier 门槛
    static constexpr float kMaxConfidenceDivisor = 50.0f; // 60→50: 同样 inlier 数得到更高 confidence
    static constexpr float kNearbyRadius = 15.0f;       // 10→15: 更大的附近搜索半径
    static constexpr int kMaxNearbyKeyframes = 15;      // 10→15: 检查更多候选关键帧
    static constexpr int kGlobalTopK = 30;              // 20→30: 更多 BoW 候选关键帧
    static constexpr int kAbsoluteDistThreshold = 60;   // 72→60: 收紧 Hamming 距离回退阈值
    static constexpr float kMinInlierRatio = 0.15f;     // NEW: PnP 结果质量门控（inlier_ratio < 15% 时拒绝）
    static constexpr float kMinBoWSimilarity = 0.05f;   // NEW: BoW 候选最低相似度过滤

    // 多帧一致性过滤参数
    static constexpr int kMaxHistoryFrames = 30;
    static constexpr float kConsistencyMadMultiplier = 3.0f;
    static constexpr float kConsistencyMinMad = 0.1f;

    // T_S_C cache for nearby keyframe selection. It is intentionally separate
    // from the current T_U_C input supplied by Unity for consistency checks.
    bool has_last_scan_from_camera_ = false;
    cv::Mat last_scan_from_camera_;  // 4×4 CV_32F

    // AKAZE fallback 相关成员
    cv::Ptr<VisualLocalizerAkaze> akaze_;
    cv::Ptr<cv::BFMatcher> akaze_matcher_;  // BFMatcher(NORM_HAMMING)

    struct AkazeKeyframeData {
        cv::Mat descriptors;                // (N, desc_len) CV_8UC1
        std::vector<cv::Point3f> points3d;
        std::vector<cv::Point2f> points2d;
    };
    std::unordered_map<int, AkazeKeyframeData> akaze_keyframes_;
    std::size_t akaze_candidate_cursor_ = 0;
    int last_successful_akaze_keyframe_id_ = -1;

    // 一致性过滤历史帧状态
    struct FrameHistory {
        cv::Mat camera_from_scan;       // T_C_S, 4×4
        cv::Mat unity_world_from_scan;  // T_U_S, 4×4
        float unity_world_from_scan_error;  // ‖T_U_S − I‖_F
    };
    std::deque<FrameHistory> frame_history_;

    // Typed passes avoid global environment changes during processing.
    enum class QueryPass { Original, ScaledFallback };
    struct FallbackStateGuard;
    struct PoolCapture {
        std::vector<joint_pool::Observation> orb[2], akaze[2];
        int pass = 0;
        int seen_orb[2] = {}, seen_akaze[2] = {};
    };
    PoolCapture* pool_capture_ = nullptr; // frame-local borrowed capture; never retained
    VLResult tryJointPool(const std::vector<joint_pool::Observation>& observations,
        int width, int height, float fx, float fy, float cx, float cy,
        const char* path, int raw_count, ReprojectionMetric* metric);
    VLResult processFrameCore(const unsigned char* image_data, int width, int height,
        float fx, float fy, float cx, float cy, bool has_unity_world_from_camera,
        const float* unity_world_from_camera_4x4, QueryPass pass, std::uint64_t ordinal);
    // Internal methods
    std::vector<float> computeBoW(const cv::Mat& descriptors);
    std::vector<KeyframeData*> getNearbyKeyframes(
        const float* scan_from_camera_4x4, float radius, int max_count);
    std::vector<KeyframeData*> getGlobalCandidates(const cv::Mat& descriptors);
    std::vector<KeyframeData*> getIndependentAkazeCandidates();
    VLResult tryMatchKeyframe(const KeyframeData& kf,
                              const std::vector<cv::KeyPoint>& query_kps,
                              const cv::Mat& query_desc,
                              float fx, float fy, float cx, float cy,
                              int* out_raw_matches = nullptr,
                              int* out_good_matches = nullptr,
                              ReprojectionMetric* out_metric = nullptr);
    VLResult tryAkazeFallback(const cv::Mat& enhanced,
                              const std::vector<KeyframeData*>& candidates,
                              float fx, float fy, float cx, float cy,
                              ReprojectionMetric* out_metric = nullptr,
                              double query_scale_x = 1.0, double query_scale_y = 1.0);
    VLResult tryMatchKeyframeAkaze(const AkazeKeyframeData& akaze_kf,
                                   const std::vector<cv::KeyPoint>& query_kps,
                                   const cv::Mat& query_desc,
                                   float fx, float fy, float cx, float cy,
                                   int* out_raw = nullptr,
                                   int* out_good = nullptr,
                                   ReprojectionMetric* out_metric = nullptr,
                                   int diagnostic_kf_id = -1);
    static int hammingDistance(const unsigned char* a, const unsigned char* b, int len);
    static float cosineSimilarity(const std::vector<float>& a, const std::vector<float>& b);
};
