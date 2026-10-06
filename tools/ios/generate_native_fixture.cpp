// Synthetic-only fixture. Compile with the three real native sources, never a stub.
#include "visual_localizer.h"
#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
constexpr int width = 640, height = 480, storedORB = 2000, minimumMatches = 100;
constexpr float fx = 500, fy = 510, cx = 320, cy = 240;
constexpr float tx = .15f, ty = -.23f, tz = .34f, poseTolerance = .01f;
static_assert(sizeof(VLResult) == 76 && sizeof(VLDebugInfo) == 48, "C API ABI changed");
struct Localizer {
    VLHandle handle = vl_create();
    ~Localizer() { vl_destroy(handle); }
};
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
}

int main(int argc, char** argv) {
    try {
        require(argc == 2, "usage: generate_native_fixture <fixture.bin>");
        const std::uint32_t endian = 1;
        require(*reinterpret_cast<const unsigned char*>(&endian) == 1 && sizeof(float) == 4,
                "fixture format requires little-endian float32 host");
        cv::setNumThreads(1);
        cv::setRNGSeed(20261004);
        cv::RNG rng(20261004);
        cv::Mat image(height, width, CV_8UC1);
        rng.fill(image, cv::RNG::UNIFORM, 0, 256);
        for (int i = 0; i < 180; ++i) {
            // Evaluate draws explicitly: C++ argument evaluation order varies by compiler.
            const int x = rng.uniform(30, width - 30), y = rng.uniform(30, height - 30);
            const int radius = rng.uniform(3, 18), gray = rng.uniform(0, 256);
            cv::circle(image, {x, y}, radius, cv::Scalar(gray), -1);
        }
        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        // Production training uses raw grayscale ORB; native query applies its own CLAHE.
        cv::ORB::create(storedORB)->detectAndCompute(image, cv::noArray(), keypoints, descriptors);
        require(descriptors.rows == storedORB && descriptors.cols == 32 && descriptors.isContinuous(),
                "synthetic image must produce 2000 raw ORB descriptors");
        const int count = descriptors.rows;
        std::vector<float> points3d, points2d;
        points3d.reserve(count * 3);
        points2d.reserve(count * 2);
        for (const auto& point : keypoints) {
            const float depth = rng.uniform(2.0f, 5.0f);
            // Vary depth to avoid planar PnP ambiguity. Scan and camera are AR axes.
            points3d.insert(points3d.end(), {depth * (point.pt.x - cx) / fx - tx,
                                            -depth * (point.pt.y - cy) / fy - ty, -depth - tz});
            points2d.insert(points2d.end(), {point.pt.x, point.pt.y});
        }
        Localizer localizer;
        require(localizer.handle != nullptr, "vl_create failed");
        for (int i = 0; i < count; ++i)
            require(vl_add_vocabulary_word(localizer.handle, i, descriptors.ptr<unsigned char>(i), 32, 1.0f),
                    "vocabulary load failed");
        // Training pose is T_S_C. Returned pose is T_C_S, its inverse here.
        const float pose[16] = {1,0,0,-tx, 0,1,0,-ty, 0,0,1,-tz, 0,0,0,1};
        require(vl_add_keyframe(localizer.handle, 7, pose, descriptors.data, count,
                                points3d.data(), points2d.data()) && vl_build_index(localizer.handle),
                "keyframe/index load failed");
        VLResult positive{};
        vl_process_frame_out(localizer.handle, image.data, width, height, fx, fy, cx, cy, 0, nullptr, &positive);
        VLDebugInfo debug{};
        vl_get_debug_info(localizer.handle, &debug);
        float maxError = 0;
        const float expected[16] = {1,0,0,tx, 0,1,0,ty, 0,0,1,tz, 0,0,0,1};
        for (int i = 0; i < 16; ++i) {
            require(std::isfinite(positive.pose[i]), "native pose is not finite");
            maxError = std::max(maxError, std::fabs(positive.pose[i] - expected[i]));
        }
        require(positive.state == 1 && positive.matched_features >= minimumMatches && maxError < poseTolerance,
                "real ORB/BoW/matching/PnP known-pose smoke failed");
        vl_reset(localizer.handle);
        cv::Mat blank(height, width, CV_8UC1, cv::Scalar(0));
        VLResult lost{};
        vl_process_frame_out(localizer.handle, blank.data, width, height, fx, fy, cx, cy, 0, nullptr, &lost);
        require(lost.state == 2 && lost.matched_features == 0 && lost.confidence == 0,
                "blank query must return LOST without matches/confidence");
        VLResult invalid{};
        vl_process_frame_out(nullptr, image.data, width, height, fx, fy, cx, cy, 0, nullptr, &invalid);
        require(invalid.state == 2 && invalid.matched_features == 0 && invalid.confidence == 0,
                "null handle must return safe LOST");
        // Ambiguous ORB train rows force the real AKAZE fallback.
        cv::Mat enhanced, akazeDescriptors;
        cv::createCLAHE(2.0, cv::Size(8, 8))->apply(image, enhanced);
        std::vector<cv::KeyPoint> akazeKeypoints;
        cv::xfeatures2d::AKAZE::create()->detectAndCompute(enhanced, cv::noArray(), akazeKeypoints, akazeDescriptors);
        const int akazeCount = std::min(600, akazeDescriptors.rows), akazeLength = akazeDescriptors.cols;
        require(akazeCount >= 100 && akazeLength == 61, "AKAZE descriptor format/count changed");
        std::vector<float> akazePoints3d, akazePoints2d;
        cv::RNG akazeRng(714);
        for (int i = 0; i < akazeCount; ++i) {
            const auto& point = akazeKeypoints[i].pt;
            const float depth = akazeRng.uniform(2.0f, 5.0f);
            akazePoints3d.insert(akazePoints3d.end(), {depth * (point.x - cx) / fx - tx,
                                                     -depth * (point.y - cy) / fy - ty, -depth - tz});
            akazePoints2d.insert(akazePoints2d.end(), {point.x, point.y});
        }
        Localizer fallback;
        const unsigned char word[32] = {};
        const std::vector<unsigned char> ambiguousORB(akazeCount * 32, 0);
        require(vl_add_vocabulary_word(fallback.handle, 0, word, 32, 1.0f) &&
                vl_add_keyframe(fallback.handle, 7, pose, ambiguousORB.data(), akazeCount,
                                akazePoints3d.data(), akazePoints2d.data()) &&
                vl_add_keyframe_akaze(fallback.handle, 7, akazeDescriptors.data, akazeCount, akazeLength,
                                      akazePoints3d.data(), akazePoints2d.data()) && vl_build_index(fallback.handle),
                "AKAZE fixture/index load failed");
        VLResult akazeResult{};
        VLDebugInfo akazeDebug{};
        vl_process_frame_out(fallback.handle, image.data, width, height, fx, fy, cx, cy, 0, nullptr, &akazeResult);
        vl_get_debug_info(fallback.handle, &akazeDebug);
        float akazeError = 0;
        for (int i = 0; i < 16; ++i) {
            require(std::isfinite(akazeResult.pose[i]), "AKAZE pose must be finite");
            akazeError = std::max(akazeError, std::fabs(akazeResult.pose[i] - expected[i]));
        }
        require(akazeResult.state == 1 && akazeResult.matched_features >= 100 && akazeError < poseTolerance &&
                akazeDebug.akaze_triggered == 1 && akazeDebug.akaze_best_inliers == akazeResult.matched_features,
                "real forced AKAZE fallback known-pose smoke failed");
        std::ofstream akazeOutput(std::string(argv[1]) + ".akaze", std::ios::binary);
        const std::int32_t akazeHeader[2] = {akazeCount, akazeLength};
        akazeOutput.write(reinterpret_cast<const char*>(akazeHeader), sizeof(akazeHeader));
        akazeOutput.write(reinterpret_cast<const char*>(image.data), width * height);
        akazeOutput.write(reinterpret_cast<const char*>(akazeDescriptors.data), akazeCount * akazeLength);
        akazeOutput.write(reinterpret_cast<const char*>(akazePoints3d.data()), akazeCount * 3 * sizeof(float));
        akazeOutput.write(reinterpret_cast<const char*>(akazePoints2d.data()), akazeCount * 2 * sizeof(float));
        akazeOutput.close();
        require(akazeOutput.good(), "AKAZE fixture write failed");
        // Only write after the native smoke has passed.
        std::ofstream output(argv[1], std::ios::binary);
        require(output.good(), "cannot create fixture.bin");
        const std::int32_t binaryCount = count;
        output.write(reinterpret_cast<const char*>(&binaryCount), sizeof(binaryCount));
        output.write(reinterpret_cast<const char*>(image.data), width * height);
        output.write(reinterpret_cast<const char*>(descriptors.data), count * 32);
        output.write(reinterpret_cast<const char*>(points3d.data()), count * 3 * sizeof(float));
        output.write(reinterpret_cast<const char*>(points2d.data()), count * 2 * sizeof(float));
        output.close();
        require(output.good(), "fixture.bin write failed");
        std::cout << std::setprecision(9)
                  << "{\"producerOpenCVVersion\":\"" << CV_VERSION << "\",\"featureCount\":" << count
                  << ",\"state\":" << positive.state << ",\"matchedFeatures\":" << positive.matched_features
                  << ",\"confidence\":" << positive.confidence << ",\"maxPoseElementError\":" << maxError
                  << ",\"queryORB\":" << debug.orb_keypoints << ",\"blankState\":" << lost.state
                  << ",\"blankMatchedFeatures\":" << lost.matched_features
                  << ",\"blankConfidence\":" << lost.confidence
                  << ",\"akazeState\":" << akazeResult.state << ",\"akazeTriggered\":" << akazeDebug.akaze_triggered
                  << ",\"akazeMatchedFeatures\":" << akazeResult.matched_features
                  << ",\"akazeMaxPoseElementError\":" << akazeError << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
