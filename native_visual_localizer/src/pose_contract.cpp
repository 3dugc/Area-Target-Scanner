#include "pose_contract.h"

namespace visual_localizer::pose_contract {

cv::Mat cameraFromScanFromOpenCvPnP(
    const cv::Mat& opencv_rotation,
    const cv::Mat& opencv_translation) {
    CV_Assert(opencv_rotation.rows == 3 && opencv_rotation.cols == 3);
    CV_Assert(opencv_rotation.channels() == 1);
    CV_Assert(opencv_translation.total() == 3);
    CV_Assert(opencv_translation.channels() == 1);

    cv::Mat rotation64;
    cv::Mat translation64;
    opencv_rotation.convertTo(rotation64, CV_64F);
    opencv_translation.reshape(1, 3).convertTo(translation64, CV_64F);

    cv::Mat camera_from_scan = cv::Mat::eye(4, 4, CV_32F);
    const float flip[3] = {1.0f, -1.0f, -1.0f};
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            camera_from_scan.at<float>(row, column) =
                flip[row] * static_cast<float>(rotation64.at<double>(row, column));
        }
        camera_from_scan.at<float>(row, 3) =
            flip[row] * static_cast<float>(translation64.at<double>(row, 0));
    }

    return camera_from_scan;
}

}  // namespace visual_localizer::pose_contract
