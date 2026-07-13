#pragma once

#include <opencv2/core.hpp>

namespace visual_localizer::pose_contract {

/// Converts an OpenCV PnP S -> camera extrinsic to the canonical AR
/// T_C_S row-major matrix. The OpenCV-camera -> AR-camera Y/Z flip occurs
/// exactly once, by left-multiplication.
cv::Mat cameraFromScanFromOpenCvPnP(
    const cv::Mat& opencv_rotation,
    const cv::Mat& opencv_translation);

}  // namespace visual_localizer::pose_contract
