#include <cmath>
#include <iostream>

#include <opencv2/core.hpp>

#include "pose_contract.h"

namespace {

bool approximatelyEqual(float actual, float expected) {
    return std::fabs(actual - expected) <= 1e-5f;
}

}  // namespace

int main() {
    // This OpenCV PnP input maps to the cameraFromScan values in
    // tests/fixtures/phase1/coordinate-contract-v1.json after the one
    // required OpenCV-camera -> AR-camera Y/Z normalization.
    const cv::Mat opencv_rotation =
        (cv::Mat_<double>(3, 3) << 1.0, 0.0, 0.0,
                                      0.0, -1.0, 0.0,
                                      0.0, 0.0, -1.0);
    const cv::Mat opencv_translation =
        (cv::Mat_<double>(3, 1) << 4.0, -5.0, -6.0);

    const cv::Mat actual = visual_localizer::pose_contract::
        cameraFromScanFromOpenCvPnP(opencv_rotation, opencv_translation);

    const float expected[16] = {
        1.0f, 0.0f, 0.0f, 4.0f,
        0.0f, 1.0f, 0.0f, 5.0f,
        0.0f, 0.0f, 1.0f, 6.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };

    if (actual.type() != CV_32F || actual.rows != 4 || actual.cols != 4) {
        std::cerr << "expected a 4x4 CV_32F T_C_S matrix" << std::endl;
        return 1;
    }

    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            const int index = row * 4 + column;
            if (!approximatelyEqual(actual.at<float>(row, column), expected[index])) {
                std::cerr << "unexpected T_C_S entry at row " << row
                          << ", column " << column << std::endl;
                return 1;
            }
        }
    }

    return 0;
}
