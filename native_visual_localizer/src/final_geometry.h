#pragma once
#include <opencv2/core.hpp>
#if CV_VERSION_MAJOR >= 5
#include <opencv2/geometry.hpp>
#else
#include <opencv2/calib3d.hpp>
#endif
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <vector>

namespace final_geometry {
struct Validation {
    bool accepted = false;
    const char* reason = "invalid_refined_geometry";
    cv::Mat rotation;
    double minimum_depth = std::numeric_limits<double>::infinity();
    double maximum_error = 0.;
    double rmse = 0.;
};

inline bool validInlierIndices(const cv::Mat& inliers, std::size_t count) {
    if (inliers.empty() || inliers.dims != 2 || inliers.type() != CV_32SC1 || inliers.cols != 1) return false;
    std::set<int> selected;
    for (int i=0; i<inliers.rows; ++i) {
        const int index=inliers.at<int>(i,0);
        if (index<0 || static_cast<std::size_t>(index)>=count || !selected.insert(index).second) return false;
    }
    return true;
}

// Validate the actual RANSAC indices after refinement, on the original pixel
// grid. Perspective division alone cannot distinguish points behind a camera.
inline Validation validateTransform(bool pnp_success,
    const std::vector<cv::Point3f>& object, const std::vector<cv::Point2f>& image,
    const cv::Mat& camera, const cv::Mat& rotation, const cv::Mat& translation,
    const cv::Mat& inliers, double maximum_original_pixel_error) {
    Validation out;
    if (!pnp_success) { out.reason = "pnp_failed"; return out; }
    if (object.size() != image.size() || object.empty() || !validInlierIndices(inliers,object.size()) ||
        !std::isfinite(maximum_original_pixel_error) || maximum_original_pixel_error < 0.) {
        out.reason = "invalid_pnp_inlier_indices"; return out;
    }
    if (rotation.rows != 3 || rotation.cols != 3 || rotation.channels() != 1 ||
        translation.total() != 3 || translation.channels() != 1 ||
        camera.rows != 3 || camera.cols != 3 || camera.channels() != 1) return out;
    cv::Mat r, t, k;
    rotation.convertTo(r, CV_64F);
    translation.reshape(1, 3).convertTo(t, CV_64F);
    camera.convertTo(k, CV_64F);
    if (!cv::checkRange(r) || !cv::checkRange(t) || !cv::checkRange(k) ||
        k.at<double>(0,0) <= 0. || k.at<double>(1,1) <= 0. ||
        std::abs(cv::determinant(r)-1.) > 1e-4 ||
        cv::norm(r.t()*r-cv::Mat::eye(3,3,CV_64F),cv::NORM_INF) > 1e-4) return out;
    // Pose conversion rounds each entry to Float32 before the AR-camera sign
    // normalization. Check that exact public geometry, without changing it.
    cv::Mat r32,t32,public_r,public_t;
    r.convertTo(r32,CV_32F); t.convertTo(t32,CV_32F);
    if (!cv::checkRange(r32) || !cv::checkRange(t32)) return out;
    r32.convertTo(public_r,CV_64F); t32.convertTo(public_t,CV_64F);
    out.rotation = r;
    double squared = 0.;
    for (int i=0; i<inliers.rows; ++i) {
        const int index = inliers.at<int>(i,0);
        const auto& p=object[index]; const auto& q=image[index];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z) ||
            !std::isfinite(q.x) || !std::isfinite(q.y)) return out;
        const double x=public_r.at<double>(0,0)*p.x+public_r.at<double>(0,1)*p.y+public_r.at<double>(0,2)*p.z+public_t.at<double>(0);
        const double y=public_r.at<double>(1,0)*p.x+public_r.at<double>(1,1)*p.y+public_r.at<double>(1,2)*p.z+public_t.at<double>(1);
        const double z=public_r.at<double>(2,0)*p.x+public_r.at<double>(2,1)*p.y+public_r.at<double>(2,2)*p.z+public_t.at<double>(2);
        if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return out;
        out.minimum_depth=std::min(out.minimum_depth,z);
        if (z <= 0.) { out.reason="nonpositive_refined_depth"; return out; }
        const double u=k.at<double>(0,0)*x/z+k.at<double>(0,2);
        const double v=k.at<double>(1,1)*y/z+k.at<double>(1,2);
        const double error=std::hypot(u-q.x,v-q.y);
        if (!std::isfinite(u) || !std::isfinite(v) || !std::isfinite(error)) return out;
        out.maximum_error=std::max(out.maximum_error,error); squared+=error*error;
        if (error > maximum_original_pixel_error) { out.reason="refined_original_pixel_gate"; return out; }
    }
    out.rmse=std::sqrt(squared/inliers.rows);
    out.reason="accepted"; out.accepted=true;
    return out;
}

inline Validation validatePnP(bool pnp_success,
    const std::vector<cv::Point3f>& object, const std::vector<cv::Point2f>& image,
    const cv::Mat& camera, const cv::Mat& rvec, const cv::Mat& tvec,
    const cv::Mat& inliers, double maximum_original_pixel_error) {
    Validation invalid;
    if (!pnp_success) { invalid.reason="pnp_failed"; return invalid; }
    if (rvec.total()!=3 || rvec.channels()!=1 || !cv::checkRange(rvec) ||
        (rvec.depth()!=CV_32F && rvec.depth()!=CV_64F)) return invalid;
    try {
        cv::Mat rotation; cv::Rodrigues(rvec,rotation);
        return validateTransform(pnp_success,object,image,camera,rotation,tvec,inliers,maximum_original_pixel_error);
    } catch(const cv::Exception&) { return invalid; }
}
} // namespace final_geometry
