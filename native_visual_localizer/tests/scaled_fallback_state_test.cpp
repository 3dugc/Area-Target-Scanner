#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#include <opencv2/imgproc.hpp>
#include <deque>
#include <unordered_map>
#include <vector>
#include <sstream>
#include <iomanip>
#include <stdexcept>
#include <iostream>
#include <cstring>
// Inspect native state without introducing a test-only production API.
#define private public
#include "visual_localizer_impl.h"
#undef private

static void require(bool ok, const char* message) { if(!ok) throw std::runtime_error(message); }
template<class T> static void append(std::string& out,const T& v) { out.append(reinterpret_cast<const char*>(&v),sizeof(v)); }
static void appendMat(std::string& out,const cv::Mat& m) { append(out,m.rows);append(out,m.cols); if(!m.empty()) out.append(reinterpret_cast<const char*>(m.data),m.total()*m.elemSize()); }
static std::string state(const VisualLocalizer& v) {
    std::string out;append(out,v.has_last_scan_from_camera_);appendMat(out,v.last_scan_from_camera_);
    append(out,v.akaze_candidate_cursor_);append(out,v.last_successful_akaze_keyframe_id_);
    auto n=v.frame_history_.size();append(out,n);
    for(const auto& h:v.frame_history_) {appendMat(out,h.camera_from_scan);appendMat(out,h.unity_world_from_scan);append(out,h.unity_world_from_scan_error);}
    append(out,v.diagnostic_frame_ordinal_);return out;
}
static cv::Mat image(int seed) {
    cv::RNG rng(seed);cv::Mat m(1440,1920,CV_8UC1);rng.fill(m,cv::RNG::UNIFORM,0,256);return m;
}
static void map(VisualLocalizer& v,int id,const cv::Mat& original,bool scaled) {
    cv::Mat grid=original,enhanced,desc;if(scaled) cv::resize(original,grid,{1600,1200},0,0,cv::INTER_AREA);
    cv::createCLAHE(2.0,{8,8})->apply(grid,enhanced);std::vector<cv::KeyPoint> kp;
    cv::ORB::create(3000)->detectAndCompute(enhanced,cv::noArray(),kp,desc);
    if(scaled) {
        cv::Mat oe,od;std::vector<cv::KeyPoint> ok;cv::createCLAHE(2.0,{8,8})->apply(original,oe);cv::ORB::create(3000)->detectAndCompute(oe,cv::noArray(),ok,od);
        std::vector<std::vector<cv::DMatch>> reverse;cv::BFMatcher(cv::NORM_HAMMING).knnMatch(desc,od,reverse,2);
        cv::Mat selected;std::vector<cv::KeyPoint> sk;
        for(int i=0;i<desc.rows;++i) if(reverse[i].size()<2 || reverse[i][0].distance>=.75f*reverse[i][1].distance) {selected.push_back(desc.row(i));sk.push_back(kp[i]);}
        desc=selected;kp=std::move(sk);
    }
    require(desc.rows>=600,"fixture features");std::vector<float> xyz,xy;cv::RNG rng(714);
    const double sx=double(grid.cols)/1920,sy=double(grid.rows)/1440;
    for(int i=0;i<600;++i) {float z=rng.uniform(2.f,5.f);auto p=kp[i].pt;
        xyz.insert(xyz.end(),{float(z*(p.x/sx-960.25)/1560-.15),float(-z*(p.y/sy-721.75)/1540+.23),-z-.34f});xy.insert(xy.end(),{p.x,p.y});}
    const float pose[]={1,0,0,-.15f,0,1,0,.23f,0,0,1,-.34f,0,0,0,1};
    v.addKeyframe(id,pose,desc.data,600,xyz.data(),xy.data());
}
static VLResult run(VisualLocalizer& v,const cv::Mat& m,bool enabled,const float* ar) {
    require(v.setRecoveryMode(enabled ? 1 : 0),"mode configuration failed");
    return v.processFrame(m.data,m.cols,m.rows,1560,1540,960.25,721.75,ar!=nullptr,ar);
}
int main() {
 try {
    cv::setNumThreads(1);unsetenv("VL_DIAGNOSTIC_TRACE");unsetenv("VL_DIAGNOSTIC_QUERY_LONG_EDGE");unsetenv("VL_DIAGNOSTIC_JOINT_POOL");
    const auto original=image(20261008),fallback=image(20261108);const cv::Mat blank=cv::Mat::zeros(original.size(),CV_8UC1);
    VisualLocalizer off,on;const unsigned char word[32]={};for(auto* v:{&off,&on}) {v->addVocabularyWord(0,word,32,1);map(*v,7,original,false);map(*v,8,fallback,true);
      // The blank frames drive independent AKAZE batches beyond 30 references.
      const std::vector<unsigned char> zero_desc(32*8,0),zero_akaze(61*8,0);float xyz[24]={},xy[16]={};const float p[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
      for(int i=0;i<72;++i) {v->addKeyframe(100+i,p,zero_desc.data(),8,xyz,xy);v->addKeyframeAkaze(100+i,zero_akaze.data(),8,61,xyz,xy);}v->buildIndex();
    }
    const float ar[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    int accepted_fallbacks=0,original_successes=0;
    std::uint64_t seed=20261008;
    for(int i=0;i<32;++i) {
      // Original successes, recoverable scaled-only queries, and lost queries
      // on one handle per setting, with one map load and nonempty AR history.
      const auto& frame=i%4==0?blank:i%4==2?fallback:original;const auto unchanged=frame.clone();
      cv::theRNG().state=seed;auto a=run(off,frame,false,ar);auto rng_after_original=cv::theRNG().state;
      cv::theRNG().state=seed;auto b=run(on,frame,true,ar);auto rng_after_candidate=cv::theRNG().state;
      require(state(off)==state(on),"all native temporal/cache/history/cursor/ordinal state must equal original after each frame");
      require(rng_after_original==rng_after_candidate,"fallback must restore post-original native RNG state");seed=rng_after_original;
      require(cv::norm(frame,unchanged,cv::NORM_INF)==0,"caller image bytes changed");
      if(a.state==1) {++original_successes;require(std::memcmp(&a,&b,sizeof(a))==0,"original success VLResult bytes differ");auto da=off.getDebugInfo(),db=on.getDebugInfo();require(std::memcmp(&da,&db,sizeof(da))==0,"original success debug bytes differ");require(off.getReprojectionMetric().valid==on.getReprojectionMetric().valid && off.getReprojectionMetric().rmse_px==on.getReprojectionMetric().rmse_px,"original success RMSE differs");}
      else if(b.state==1) ++accepted_fallbacks;
      else {auto da=off.getDebugInfo(),db=on.getDebugInfo();require(std::memcmp(&a,&b,sizeof(a))==0 && std::memcmp(&da,&db,sizeof(da))==0,"failed fallback must restore original public result/debug");}
    }
    require(original_successes>=8,"sequence must contain original accepted poses");require(accepted_fallbacks>=4,"sequence must exercise accepted fallback state rollback");
    // Existing consistency rejection is a geometric pose and cannot trigger fallback.
    float bad_ar[16];std::memcpy(bad_ar,ar,sizeof(ar));bad_ar[3]=100;
    auto a=run(off,original,false,bad_ar),b=run(on,original,true,bad_ar);auto da=off.getDebugInfo(),db=on.getDebugInfo();
    require(a.state==2 && da.consistency_rejected==1,"fixture must reject original pose for consistency");require(std::memcmp(&a,&b,sizeof(a))==0 && std::memcmp(&da,&db,sizeof(da))==0 && state(off)==state(on),"consistency rejection bypassed or state changed");
    auto lost_original=run(off,fallback,false,bad_ar), rejected_fallback=run(on,fallback,true,bad_ar);
    auto lost_debug=off.getDebugInfo(), rejected_debug=on.getDebugInfo();
    require(lost_original.state==2 && lost_debug.consistency_rejected==0,"fallback rejection fixture original must be geometric LOST");
    require(std::memcmp(&lost_original,&rejected_fallback,sizeof(lost_original))==0 && std::memcmp(&lost_debug,&rejected_debug,sizeof(lost_debug))==0 && state(off)==state(on),"fallback consistency rejection must restore original public debug/result and all state");
    std::cout<<"{\"frames\":32,\"original_success_byte_parity\":"<<original_successes<<",\"accepted_fallbacks\":"<<accepted_fallbacks<<",\"state_and_rng_parity_each_frame\":true,\"consistency_rejected_preserved\":true}\n";
 } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
