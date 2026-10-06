#include "visual_localizer.h"

#include <opencv2/core.hpp>
#if CV_VERSION_MAJOR >= 5
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
using TestAkaze = cv::xfeatures2d::AKAZE;
#else
#include <opencv2/features2d.hpp>
using TestAkaze = cv::AKAZE;
#endif
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int kWidth = 640, kHeight = 480;
constexpr float kFx = 500, kFy = 510, kCx = 320, kCy = 240;
constexpr float kTx = .15f, kTy = -.23f, kTz = .34f;
const float kExpectedPose[16] = {1,0,0,kTx, 0,1,0,kTy, 0,0,1,kTz, 0,0,0,1};
const float kTrainingPose[16] = {1,0,0,-kTx, 0,1,0,-kTy, 0,0,1,-kTz, 0,0,0,1};
static_assert(sizeof(VLResult) == 76 && sizeof(VLDebugInfo) == 48, "C ABI changed");

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct Localizer {
    VLHandle handle = vl_create();
    Localizer() { require(handle != nullptr, "vl_create failed"); }
    ~Localizer() { vl_destroy(handle); }
};

cv::Mat image() {
    cv::RNG rng(20261005);
    cv::Mat gray(kHeight, kWidth, CV_8UC1);
    rng.fill(gray, cv::RNG::UNIFORM, 0, 256);
    for (int i = 0; i < 150; ++i) {
        const int x = rng.uniform(30, kWidth - 30);
        const int y = rng.uniform(30, kHeight - 30);
        const int radius = rng.uniform(3, 18);
        const int value = rng.uniform(0, 256);
        cv::circle(gray, {x, y}, radius, cv::Scalar(value), -1);
    }
    return gray;
}

void pointsFor(const std::vector<cv::KeyPoint>& keypoints, int count,
               std::vector<float>& points3d, std::vector<float>& points2d) {
    cv::RNG rng(714);
    for (int i = 0; i < count; ++i) {
        const auto& point = keypoints[i].pt;
        const float depth = rng.uniform(2.0f, 5.0f);
        // Non-coplanar geometry in AR axes; PnP must recover kExpectedPose.
        points3d.insert(points3d.end(), {depth * (point.x - kCx) / kFx - kTx,
                                      -depth * (point.y - kCy) / kFy - kTy, -depth - kTz});
        points2d.insert(points2d.end(), {point.x, point.y});
    }
}

VLResult process(VLHandle handle, const cv::Mat& gray) {
    VLResult result{};
    vl_process_frame_out(handle, gray.data, gray.cols, gray.rows,
                         kFx, kFy, kCx, kCy, 0, nullptr, &result);
    return result;
}

void requireLost(const VLResult& result) {
    require(result.state == 2 && result.confidence == 0 && result.matched_features == 0,
            "blank/invalid input must return safe LOST");
    for (int i = 0; i < 16; ++i)
        require(result.pose[i] == ((i % 5 == 0) ? 1.0f : 0.0f), "LOST pose must be identity");
}

void knownPose(bool fallback) {
    Localizer localizer;
    const cv::Mat gray = image();
    cv::Mat enhanced;
    cv::createCLAHE(2.0, cv::Size(8, 8))->apply(gray, enhanced);
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    cv::Ptr<cv::Feature2D> extractor;
    if (fallback) extractor = TestAkaze::create();
    else extractor = cv::ORB::create(3000);
    extractor->detectAndCompute(enhanced, cv::noArray(), keypoints, descriptors);
    const int count = std::min(600, descriptors.rows);
    require(count >= 100, "synthetic query must contain at least 100 features");
    std::vector<float> points3d, points2d;
    pointsFor(keypoints, count, points3d, points2d);
    const unsigned char word[32] = {};
    // One vocabulary word keeps candidate retrieval deterministic and cheap.
    require(vl_add_vocabulary_word(localizer.handle, 0, word, 32, 1.0f), "vocabulary load failed");
    if (fallback) {
        require(descriptors.cols == 61 && descriptors.type() == CV_8UC1,
                "default AKAZE MLDB byte format changed");
        // Equal ORB train descriptors fail bidirectional ratio checking while
        // still producing a valid BoW candidate. Real AKAZE must recover it.
        const std::vector<unsigned char> ambiguous_orb(count * 32, 0);
        require(vl_add_keyframe(localizer.handle, 7, kTrainingPose, ambiguous_orb.data(), count,
                                points3d.data(), points2d.data()), "ORB keyframe load failed");
        require(vl_add_keyframe_akaze(localizer.handle, 7, descriptors.data, count, descriptors.cols,
                                     points3d.data(), points2d.data()), "AKAZE keyframe load failed");
    } else {
        require(descriptors.cols == 32 && descriptors.type() == CV_8UC1, "ORB byte format changed");
        require(vl_add_keyframe(localizer.handle, 7, kTrainingPose, descriptors.data, count,
                                points3d.data(), points2d.data()), "ORB keyframe load failed");
    }
    require(vl_build_index(localizer.handle), "build index failed");
    const VLResult result = process(localizer.handle, gray);
    VLDebugInfo debug{};
    vl_get_debug_info(localizer.handle, &debug);
    require(result.state == 1 && result.matched_features >= 100, "known pose must localize with real features/PnP");
    require(std::isfinite(result.confidence) && result.confidence > 0 && result.confidence <= 1,
            "successful localization confidence must be finite and in (0,1]");
    require(debug.akaze_triggered == (fallback ? 1 : 0), "unexpected fallback path");
    if (fallback)
        require(debug.akaze_best_inliers == result.matched_features, "AKAZE result/debug inliers must agree");
    float error = 0;
    for (int i = 0; i < 16; ++i) {
        require(std::isfinite(result.pose[i]), "pose must be finite");
        error = std::max(error, std::fabs(result.pose[i] - kExpectedPose[i]));
    }
    require(error < .01f, "known pose error exceeds 0.01");
    std::cout << (fallback ? "AKAZE" : "ORB") << " OpenCV=" << CV_VERSION
              << " inliers=" << result.matched_features << " maxPoseError=" << error << '\n';
    vl_reset(localizer.handle);
    const cv::Mat blank(kHeight, kWidth, CV_8UC1, cv::Scalar(0));
    requireLost(process(localizer.handle, blank));
}

void invalidInput() {
    Localizer localizer;
    const unsigned char pixel = 0;
    VLResult result{};
    for (const auto& dimensions : std::vector<cv::Size>{{0, 1}, {1, 0}, {-1, 1}, {1, -1}}) {
        vl_process_frame_out(localizer.handle, &pixel, dimensions.width, dimensions.height,
                             kFx, kFy, kCx, kCy, 0, nullptr, &result);
        requireLost(result);
    }
    vl_process_frame_out(localizer.handle, nullptr, 1, 1, kFx, kFy, kCx, kCy, 0, nullptr, &result);
    requireLost(result);
    vl_process_frame_out(nullptr, &pixel, 1, 1, kFx, kFy, kCx, kCy, 0, nullptr, &result);
    requireLost(result);
    vl_process_frame_out(localizer.handle, &pixel, 1, 1, kFx, kFy, kCx, kCy, 0, nullptr, nullptr);
}
}  // namespace

int main(int argc, char** argv) {
    try {
        require(argc == 2, "usage: localization_contract_test orb|akaze|invalid");
        cv::setNumThreads(1);
        cv::setRNGSeed(20261005);
        const std::string mode = argv[1];
        if (mode == "orb") knownPose(false);
        else if (mode == "akaze") knownPose(true);
        else if (mode == "invalid") invalidInput();
        else throw std::runtime_error("unknown test mode");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
