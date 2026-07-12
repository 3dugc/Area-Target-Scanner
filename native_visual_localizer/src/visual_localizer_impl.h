#pragma once
#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <deque>
#include <unordered_map>
#include <vector>
#include "visual_localizer.h"

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

    VLResult processFrame(const unsigned char* image_data, int width, int height,
                          float fx, float fy, float cx, float cy,
                          bool has_last_pose, const float* last_pose_4x4);
    void reset();

    // 坐标系对齐变换: 设置预计算的 4×4 Alignment_Transform
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

    // Debug diagnostics for last processed frame
    VLDebugInfo last_debug_info_ = {};

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

    // 坐标系对齐变换状态
    bool has_alignment_transform_ = false;
    cv::Mat alignment_transform_;  // 4×4 CV_32F

    // AKAZE fallback 相关成员
    cv::Ptr<cv::AKAZE> akaze_;
    cv::Ptr<cv::BFMatcher> akaze_matcher_;  // BFMatcher(NORM_HAMMING)

    struct AkazeKeyframeData {
        cv::Mat descriptors;                // (N, desc_len) CV_8UC1
        std::vector<cv::Point3f> points3d;
        std::vector<cv::Point2f> points2d;
    };
    std::unordered_map<int, AkazeKeyframeData> akaze_keyframes_;

    // 一致性过滤历史帧状态
    struct FrameHistory {
        cv::Mat pose;       // 4×4 w2c 位姿
        cv::Mat s2a;        // 4×4 scanToAR 矩阵
        float s2a_err;      // ‖s2a − I‖_F
    };
    std::deque<FrameHistory> frame_history_;

    // Internal methods
    std::vector<float> computeBoW(const cv::Mat& descriptors);
    std::vector<KeyframeData*> getNearbyKeyframes(const float* last_pose, float radius, int max_count);
    std::vector<KeyframeData*> getGlobalCandidates(const cv::Mat& descriptors);
    VLResult tryMatchKeyframe(const KeyframeData& kf,
                              const std::vector<cv::KeyPoint>& query_kps,
                              const cv::Mat& query_desc,
                              float fx, float fy, float cx, float cy,
                              int* out_raw_matches = nullptr,
                              int* out_good_matches = nullptr);
    VLResult tryAkazeFallback(const cv::Mat& enhanced,
                              const std::vector<KeyframeData*>& candidates,
                              float fx, float fy, float cx, float cy);
    VLResult tryMatchKeyframeAkaze(const AkazeKeyframeData& akaze_kf,
                                   const std::vector<cv::KeyPoint>& query_kps,
                                   const cv::Mat& query_desc,
                                   float fx, float fy, float cx, float cy,
                                   int* out_raw = nullptr,
                                   int* out_good = nullptr);
    static int hammingDistance(const unsigned char* a, const unsigned char* b, int len);
    static float cosineSimilarity(const std::vector<float>& a, const std::vector<float>& b);
};
