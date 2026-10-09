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
#include <dlfcn.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <fstream>
#include <cstdlib>
#include <cstdio>
#include <unistd.h>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
struct Native {
    void* library;
    decltype(&vl_create) create;
    decltype(&vl_destroy) destroy;
    decltype(&vl_add_vocabulary_word) word;
    decltype(&vl_add_keyframe) orb;
    decltype(&vl_add_keyframe_akaze) akaze;
    decltype(&vl_build_index) build;
    decltype(&vl_process_frame_out) process;
    decltype(&vl_get_debug_info) debug;
    int (*set_mode)(VLHandle,int) = nullptr;
    int recovery_mode = 0;
    explicit Native(const char* path) : library(dlopen(path, RTLD_NOW | RTLD_LOCAL)) {
        if (!library) throw std::runtime_error(dlerror());
#define LOAD(member, symbol) member = reinterpret_cast<decltype(member)>(dlsym(library, #symbol)); require(member != nullptr, "missing " #symbol)
        LOAD(create, vl_create); LOAD(destroy, vl_destroy);
        LOAD(word, vl_add_vocabulary_word); LOAD(orb, vl_add_keyframe);
        LOAD(akaze, vl_add_keyframe_akaze); LOAD(build, vl_build_index);
        LOAD(process, vl_process_frame_out); LOAD(debug, vl_get_debug_info);
        set_mode = reinterpret_cast<decltype(set_mode)>(dlsym(library,"vl_set_recovery_mode"));
#undef LOAD
    }
    ~Native() { dlclose(library); }
};
struct NoiseTrace {
    std::string path;
    bool owned=false;
    explicit NoiseTrace(bool needed) {
        if(!needed) return;
        const char* existing=std::getenv("VL_DIAGNOSTIC_TRACE");
        if(existing && *existing) path=existing;
        else {char pattern[]="/tmp/vl-final-pixel-contract-XXXXXX";int fd=mkstemp(pattern);
            require(fd>=0,"cannot create final-pixel contract trace");close(fd);path=pattern;owned=true;
            setenv("VL_DIAGNOSTIC_TRACE",path.c_str(),1);}
    }
    ~NoiseTrace(){if(owned){unsetenv("VL_DIAGNOSTIC_TRACE");std::remove(path.c_str());}}
    void requireFinalPixelRejection(const char* feature_path) const {
        std::ifstream input(path);std::string line;bool seen=false;
        while(std::getline(input,line)) if(line.find("\"event\":\"final_geometry\"")!=std::string::npos &&
            line.find("\"phase\":\"scaled_fallback\"")!=std::string::npos &&
            line.find(std::string("\"path\":\"")+feature_path+"\"")!=std::string::npos &&
            line.find("\"accepted\":false")!=std::string::npos &&
            line.find("\"rejection_reason\":\"refined_original_pixel_gate\"")!=std::string::npos) seen=true;
        require(seen,"noisy fixture must be rejected by final original-pixel geometry, not merely LOST");
    }
};
template<class T> std::string bytes(const T& value) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    const auto* data = reinterpret_cast<const unsigned char*>(&value);
    for (std::size_t i = 0; i < sizeof(value); ++i) out << std::setw(2) << static_cast<unsigned>(data[i]);
    return out.str();
}

void knownPose(Native& api, bool fallback, bool resized, bool portrait, bool noisy, bool rounded = false) {
    const int width = rounded ? 1921 : portrait ? 1440 : 1920;
    const int height = rounded ? 1441 : portrait ? 1920 : 1440;
    const float fx = 1560.f, fy = 1540.f, cx = width * .5f + .25f, cy = height * .5f + 1.75f;
    const float tx = .15f, ty = -.23f, tz = .34f;
    const float expected[16] = {1,0,0,tx, 0,1,0,ty, 0,0,1,tz, 0,0,0,1};
    const float training[16] = {1,0,0,-tx, 0,1,0,-ty, 0,0,1,-tz, 0,0,0,1};
    cv::RNG rng(20261008);
    cv::Mat original(height, width, CV_8UC1);
    rng.fill(original, cv::RNG::UNIFORM, 0, 256);
    for (int i = 0; i < 180; ++i)
        cv::circle(original, {rng.uniform(30, width-30), rng.uniform(30, height-30)},
                   rng.uniform(4, 24), cv::Scalar(rng.uniform(0,256)), -1);
    const cv::Mat unchanged = original.clone();
    cv::Mat map_gray = original;
    // Independently construct the rounded extraction grid; K stays original.
    // 1921x1441 yields 1600x1200 and unequal x/y scale factors.
    if (resized) {
        const double ratio = 1600.0 / std::max(width, height);
        const cv::Size dimensions(std::max(1, cvRound(width * ratio)),
                                  std::max(1, cvRound(height * ratio)));
        cv::resize(original, map_gray, dimensions, 0, 0, cv::INTER_AREA);
    }
    const double sx = static_cast<double>(map_gray.cols) / width;
    const double sy = static_cast<double>(map_gray.rows) / height;
    if (rounded) require(map_gray.cols == 1600 && map_gray.rows == 1200 && sx != sy,
                         "rounded fixture must exercise unequal actual x/y scales");
    cv::Mat enhanced, descriptors;
    std::vector<cv::KeyPoint> keypoints;
    cv::createCLAHE(2.0, {8,8})->apply(map_gray, enhanced);
    cv::Ptr<cv::Feature2D> extractor;
    if (fallback) extractor = TestAkaze::create();
    else extractor = cv::ORB::create(3000);
    extractor->detectAndCompute(enhanced, cv::noArray(), keypoints, descriptors);
    if (resized) {
        cv::Mat original_enhanced, original_desc; std::vector<cv::KeyPoint> original_kp;
        cv::createCLAHE(2.0,{8,8})->apply(original,original_enhanced);
        extractor->detectAndCompute(original_enhanced,cv::noArray(),original_kp,original_desc);
        std::vector<std::vector<cv::DMatch>> reverse;
        cv::BFMatcher(cv::NORM_HAMMING).knnMatch(descriptors,original_desc,reverse,2);
        cv::Mat selected;std::vector<cv::KeyPoint> selected_kp;
        for (int i=0;i<descriptors.rows;++i) {
            // A real scaled feature with no reverse-ratio match at original
            // resolution cannot pass the original cross-check. No mocked PnP.
            if(reverse[i].size()<2 || reverse[i][0].distance >= .75f*reverse[i][1].distance) {
                selected.push_back(descriptors.row(i)); selected_kp.push_back(keypoints[i]);
            }
        }
        descriptors=selected;keypoints=std::move(selected_kp);
    }
    const int count = std::min(600, descriptors.rows);
    require(count == 600, "fixture must contain at least 600 real map features");
    std::vector<float> points3d, points2d;
    cv::RNG depths(714);
    for (int i = 0; i < count; ++i) {
        auto p = keypoints[i].pt;
        if (noisy && i >= 540) { const int direction = i % 4;
            p.x += direction == 0 ? 13.5f*sx : direction == 1 ? -13.5f*sx : 0.f;
            p.y += direction == 2 ? 13.5f*sy : direction == 3 ? -13.5f*sy : 0.f; }
        const float depth = depths.uniform(2.f,5.f);
        points3d.insert(points3d.end(), {
            static_cast<float>(depth*(p.x-cx*sx)/(fx*sx)-tx),
            static_cast<float>(-depth*(p.y-cy*sy)/(fy*sy)-ty), -depth-tz});
        points2d.insert(points2d.end(), {p.x,p.y});
    }
    VLHandle handle = api.create();
    require(handle != nullptr, "create failed");
    require(api.recovery_mode==0 || api.set_mode!=nullptr,"enhanced mode unsupported by library");
    if(api.set_mode) require(api.set_mode(handle,api.recovery_mode)==1,"mode configuration failed");
    const unsigned char word[32] = {};
    require(api.word(handle,0,word,32,1.f), "word failed");
    if (fallback) {
        const std::vector<unsigned char> ambiguous_orb(count*32,0);
        require(api.orb(handle,7,training,ambiguous_orb.data(),count,points3d.data(),points2d.data()), "orb failed");
        require(api.akaze(handle,7,descriptors.data,count,descriptors.cols,points3d.data(),points2d.data()), "akaze failed");
    } else require(api.orb(handle,7,training,descriptors.data,count,points3d.data(),points2d.data()), "orb failed");
    require(api.build(handle), "index failed");
    NoiseTrace noise_trace(noisy);
    VLResult result{};
    api.process(handle,original.data,width,height,fx,fy,cx,cy,0,nullptr,&result);
    VLDebugInfo debug{};
    api.debug(handle,&debug);
    api.destroy(handle);
    require(cv::norm(original,unchanged,cv::NORM_INF)==0, "input pixels must stay byte-identical");
    std::cout << "{\"result_bytes\":\"" << bytes(result) << "\",\"debug_bytes\":\"" << bytes(debug)
              << "\",\"state\":" << result.state << ",\"inliers\":" << result.matched_features
              << ",\"map_features\":" << keypoints.size() << ",\"query_orb_features\":" << debug.orb_keypoints
              << ",\"original_dimensions\":[" << width << "," << height << "]"
              << ",\"processed_dimensions\":[" << map_gray.cols << "," << map_gray.rows << "]"
              << ",\"scale_xy\":[" << std::setprecision(17) << sx << "," << sy << "]";
    float error=0;
    for (int i=0;i<16;++i) error=std::max(error,std::fabs(result.pose[i]-expected[i]));
    std::cout << ",\"max_pose_error\":" << std::setprecision(9) << error << "}\n";
    if(noisy) {
        require(result.state==2 && result.matched_features==0,"final inliers exceeding12px must not return success");
        noise_trace.requireFinalPixelRejection(fallback ? "AKAZE" : "ORB");
        return;
    }
    require(result.state == 1 && result.matched_features >= (noisy ? 530 : 550), "original query must recover at least 550 scaled-map inliers");
    require(std::isfinite(error) && error < .01f, "original K and remapped points must recover the independent known 3D pose");
    if (noisy) require(result.matched_features <= 580, "unchanged original-grid 12px gate must exclude near-boundary noise (unsafe scaled K accepts 600)");
    require(debug.akaze_triggered == static_cast<int>(fallback), "unexpected feature path");
    if (!fallback) require(debug.orb_keypoints == 3000, "query extraction must use map pixel dimensions before CLAHE/ORB");
}
}
int main(int argc,char** argv) {
    try {
        require((argc==3 || argc==4),"usage: scaled_fallback_contract_test orb1600|akaze1600|portrait1600|gate_orb|gate_akaze|rounded_orb|rounded_akaze|lost1600|unchanged library");
        cv::setNumThreads(1);
        cv::setRNGSeed(20261008);
        Native api(argv[2]);
        api.recovery_mode=argc==4 ? std::stoi(argv[3]) : 0;
        require(api.recovery_mode==0 || api.recovery_mode==1,"invalid fixture mode");
        const std::string mode=argv[1];
        if (mode == "lost1600") {
            cv::Mat blank(1200,1600,CV_8UC1,cv::Scalar(0));
            VLHandle handle=api.create();require(handle!=nullptr,"create failed");
            require(api.recovery_mode==0 || api.set_mode!=nullptr,"enhanced mode unsupported by library");
            if(api.set_mode) require(api.set_mode(handle,api.recovery_mode)==1,"mode configuration failed");
            VLResult result{};VLDebugInfo debug{};
            api.process(handle,blank.data,blank.cols,blank.rows,1000,1000,800,600,0,nullptr,&result);
            api.debug(handle,&debug);api.destroy(handle);
            require(result.state==2 && result.matched_features==0,"1600-edge missing matches remain LOST");
            std::cout<<"{\"result_bytes\":\""<<bytes(result)<<"\",\"debug_bytes\":\""<<bytes(debug)
                     <<"\",\"state\":2,\"inliers\":0}\n";
            return 0;
        }
        require(mode=="orb1600" || mode=="akaze1600" || mode=="portrait1600" || mode=="unchanged" || mode=="gate_orb" || mode=="gate_akaze" || mode=="rounded_orb" || mode=="rounded_akaze" || mode=="rounded_clean_orb" || mode=="rounded_clean_akaze","unknown mode");
        const bool rounded=mode=="rounded_orb" || mode=="rounded_akaze" || mode=="rounded_clean_orb" || mode=="rounded_clean_akaze";
        knownPose(api,mode=="akaze1600" || mode=="gate_akaze" || mode=="rounded_akaze" || mode=="rounded_clean_akaze",
                  mode!="unchanged",mode=="portrait1600",
                  mode=="gate_orb" || mode=="gate_akaze" || mode=="rounded_orb" || mode=="rounded_akaze",rounded);
        return 0;
    } catch(const std::exception& error) { std::cerr<<error.what()<<'\n'; return 1; }
}
