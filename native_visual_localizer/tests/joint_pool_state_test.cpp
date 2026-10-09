#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#include <opencv2/imgproc.hpp>
#include <deque>
#include <unordered_map>
#include <vector>
#include <stdexcept>
#include <iostream>
#include <cstring>
#define private public
#include "visual_localizer_impl.h"
#undef private

static void require(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
template<class T> static void append(std::string& out,const T& v) { out.append(reinterpret_cast<const char*>(&v),sizeof(v)); }
static void mat(std::string& out,const cv::Mat& m) { append(out,m.rows);append(out,m.cols); if(!m.empty()) out.append(reinterpret_cast<const char*>(m.data),m.total()*m.elemSize()); }
static std::string state(const VisualLocalizer& v) {
    std::string out;append(out,v.has_last_scan_from_camera_);mat(out,v.last_scan_from_camera_);
    append(out,v.akaze_candidate_cursor_);append(out,v.last_successful_akaze_keyframe_id_);
    auto n=v.frame_history_.size();append(out,n);
    for(const auto& h:v.frame_history_) {mat(out,h.camera_from_scan);mat(out,h.unity_world_from_scan);append(out,h.unity_world_from_scan_error);}
    append(out,v.diagnostic_frame_ordinal_);return out;
}
static cv::Mat image(int seed) { cv::RNG rng(seed);cv::Mat m(480,640,CV_8UC1);rng.fill(m,cv::RNG::UNIFORM,0,256);return m; }
static void map(VisualLocalizer& v,int id,const cv::Mat& source,bool split) {
    cv::Mat enhanced,desc;cv::createCLAHE(2,{8,8})->apply(source,enhanced);
    std::vector<cv::KeyPoint> kp;cv::ORB::create(3000)->detectAndCompute(enhanced,cv::noArray(),kp,desc);
    std::vector<int> selected; bool cells[16]={};
    for(int i=0;i<desc.rows;++i) {
        auto p=kp[i].pt;int cell=int(p.y/120)*4+int(p.x/160);
        if(cell>=0 && cell<16 && !cells[cell]) {cells[cell]=true;selected.push_back(i);}
    }
    require(selected.size()==16,"distributed fixture needs 16 cells");
    const float pose[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    for(int group=0;group<(split?4:1);++group) {
        cv::Mat d;std::vector<float> xyz,xy;
        for(int j=0;j<16;++j) if(!split || j%4==group) {
            auto p=kp[selected[j]].pt;float z=2.f+.12f*j;
            d.push_back(desc.row(selected[j]));xyz.insert(xyz.end(),{z*(p.x-320)/520,-z*(p.y-240)/515,-z});xy.insert(xy.end(),{p.x,p.y});
        }
        v.addKeyframe(id+group,pose,d.data,d.rows,xyz.data(),xy.data());
    }
}
static VLResult runSetting(VisualLocalizer& v,const cv::Mat& m,const char* setting,const float* ar=nullptr) {
    require(v.setRecoveryMode(setting && std::strcmp(setting,"1")==0 ? 1 : 0),"mode configuration failed");
    return v.processFrame(m.data,m.cols,m.rows,520,515,320,240,ar!=nullptr,ar);
}
static VLResult run(VisualLocalizer& v,const cv::Mat& m,bool enabled,const float* ar=nullptr) {
    return runSetting(v,m,enabled ? "1" : nullptr,ar);
}
int main() {
 try {
    cv::setNumThreads(1);unsetenv("VL_DIAGNOSTIC_TRACE");unsetenv("VL_DIAGNOSTIC_SCALED_FALLBACK");
    auto joint=image(20261008),original=image(20261009);auto blank=cv::Mat::zeros(joint.size(),CV_8UC1);
    VisualLocalizer off,on;const unsigned char word[32]={};
    for(auto* v:{&off,&on}) {v->addVocabularyWord(0,word,32,1);map(*v,10,joint,true);map(*v,20,original,false);v->buildIndex();}
    std::uint64_t seed=20261008;int gains=0,originals=0;
    for(int i=0;i<32;++i) {
        const cv::Mat& m=i%3==0?joint:i%3==1?original:blank;auto unchanged=m.clone();
        cv::theRNG().state=seed;auto a=run(off,m,false);auto original_rng=cv::theRNG().state;
        cv::theRNG().state=seed;auto b=run(on,m,true);
        require(state(off)==state(on),"joint changed original temporal/cache/cursor/ordinal state");
        require(cv::theRNG().state==original_rng,"joint changed post-original RNG");seed=original_rng;
        require(cv::norm(m,unchanged,cv::NORM_INF)==0,"joint changed caller pixels");
        auto da=off.getDebugInfo(),db=on.getDebugInfo();
        if(i%3==0) {require(a.state==2 && b.state==1 && b.matched_features>=8,"joint sparse map must recover without per-KF success");++gains;}
        else {require(std::memcmp(&a,&b,sizeof(a))==0 && std::memcmp(&da,&db,sizeof(da))==0,"original/failed public result debug changed");if(a.state==1)++originals;}
    }
    const float ar[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    auto a=run(off,joint,false,ar),b=run(on,joint,true,ar);
    require(a.state==2 && std::memcmp(&a,&b,sizeof(a))==0 && state(off)==state(on),"AR path must disable experimental joint candidate");
    for(const char* setting:std::vector<const char*>{nullptr,"","0","true","01","1junk"}) {
        cv::theRNG().state=seed;auto reference=run(off,joint,false);auto expected_rng=cv::theRNG().state;
        cv::theRNG().state=seed;auto unsupported=runSetting(on,joint,setting);
        auto da=off.getDebugInfo(),db=on.getDebugInfo();
        require(reference.state==2 && std::memcmp(&reference,&unsupported,sizeof(reference))==0 &&
                std::memcmp(&da,&db,sizeof(da))==0 && state(off)==state(on) &&
                cv::theRNG().state==expected_rng,"non-exact joint flags must preserve original LOST/debug/state/RNG");
        seed=expected_rng;
    }
    require(gains==11 && originals==11,"full 32 synthetic denominator");
    std::cout<<"{\"frames\":32,\"joint_returns\":"<<gains<<",\"original_returns_preserved\":"<<originals<<",\"state_and_rng_each_frame\":true,\"ar_disabled\":true}\n";
 } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
