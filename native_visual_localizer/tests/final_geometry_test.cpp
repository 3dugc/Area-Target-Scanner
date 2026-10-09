#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/geometry.hpp>
#include <deque>
#include <unordered_map>
#include <vector>
#include <stdexcept>
#include <iostream>
#include <cstring>
#include "final_geometry.h"
#define private public
#include "visual_localizer_impl.h"
#undef private

static void require(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
// Saved sequence 30 full 11 matched correspondences, unchanged original-image pixels/scan XYZ.
// Source geometry-audit.json SHA is recorded in the contract receipt.
static const double saved[][5] = {
    {1265,386,-1.4347484111785889,-0.33531570434570312,1.8896503448486328},
    {1670,945,-3.6048800945281982,-1.1709136962890625,1.2998745441436768},
    {1359.360107421875,437.760009765625,-1.1646294593811035,-0.56116402149200439,-0.11589748412370682},
    {1101.60009765625,223.20001220703125,-3.5917704105377197,-1.1869164705276489,1.1893383264541626},
    {1109.3760986328125,505.95846557617188,-1.223692774772644,-0.5246347188949585,-0.19374515116214752},
    {1094.861083984375,517.5706787109375,-1.2256689071655273,-0.52331024408340454,-0.1816570907831192},
    {1109.791015625,507.61740112304688,-1.2244386672973633,-0.52435916662216187,-0.19290842115879059},
    {1099.837646484375,505.12908935546875,-1.2280577421188354,-0.5229029655456543,-0.18687805533409119},
    {808.70416259765625,393.1546630859375,-1.2383590936660767,-0.30144417285919189,-0.20508088171482086},
    {1095.8564453125,513.58935546875,-1.2275288105010986,-0.52281296253204346,-0.18272891640663147},
    {1098.8424072265625,501.64544677734375,-1.2294411659240723,-0.52267420291900635,-0.18770593404769897}
};
static void singlePath(bool akaze) {
    VisualLocalizer v;
    cv::Mat desc(sizeof(saved)/sizeof(saved[0]),akaze?61:32,CV_8UC1);cv::RNG rng(20261030);rng.fill(desc,cv::RNG::UNIFORM,0,256);
    std::vector<cv::KeyPoint> kp;std::vector<cv::Point3f> xyz;
    for(const auto& p:saved) {kp.emplace_back(cv::Point2f(p[0],p[1]),1.f);xyz.emplace_back(p[2],p[3],p[4]);}
    const float fx=1346.4302978515625f,fy=1346.4302978515625f,cx=966.2796630859375f,cy=722.5546875f;
    cv::theRNG().state=20261008;
    VLResult r;
    if(akaze) { VisualLocalizer::AkazeKeyframeData kf;kf.descriptors=desc;kf.points3d=xyz;
        r=v.tryMatchKeyframeAkaze(kf,kp,desc,fx,fy,cx,cy,nullptr,nullptr,nullptr,36);
    } else {KeyframeData kf;kf.id=36;kf.descriptors=desc;kf.points3d=xyz;
        r=v.tryMatchKeyframe(kf,kp,desc,fx,fy,cx,cy);}
    double minimum=1e100;int negative=0;
    if(r.state==1) for(int i=3;i<11;++i) {const auto& p=xyz[i];double z=-(r.pose[8]*p.x+r.pose[9]*p.y+r.pose[10]*p.z+r.pose[11]);minimum=std::min(minimum,z);negative+=z<=0;}
    std::cout<<"path="<<(akaze?"AKAZE":"ORB")<<" state="<<r.state<<" inliers="<<r.matched_features<<" nonpositive_depths="<<negative<<" minimum_depth="<<minimum<<'\n';
    require(r.state==2,"single-keyframe path accepted saved low-error mixed-depth geometry");
}
static void validationChecks() {
    std::vector<cv::Point3f> object(8,cv::Point3f(0,0,1));
    std::vector<cv::Point2f> image(8,cv::Point2f(0,0));
    cv::Mat k=cv::Mat::eye(3,3,CV_64F),r=k.clone(),t=cv::Mat::zeros(3,1,CV_64F),indices(8,1,CV_32S);
    for(int i=0;i<8;++i)indices.at<int>(i)=i;
    auto check=[&](bool success=true){return final_geometry::validateTransform(success,object,image,k,r,t,indices,12);};
    require(check().accepted,"positive geometry rejected");
    require(!check(false).accepted,"failed PnP accepted");
    image[0].x=12;require(check().accepted && check().maximum_error==12,"exact 12 original-pixel boundary rejected");
    image[0].x=std::nextafter(12.f,INFINITY);require(!check().accepted,"post-refinement point over12px accepted");image[0].x=0;
    object[0].z=0;require(!check().accepted,"zero optical depth accepted");object[0].z=-1;
    require(!check().accepted,"mixed-depth low-error geometry accepted");
    for(auto& p:object)p.z=-1;require(!check().accepted,"all-behind low-error geometry accepted");
    for(auto& p:object)p.z=1;
    indices.at<int>(7)=0;require(!check().accepted,"duplicate actual inlier index accepted");
    indices.at<int>(7)=8;require(!check().accepted,"out-of-range actual inlier index accepted");indices.at<int>(7)=7;
    object.push_back(cv::Point3f(0,0,-1));image.push_back(cv::Point2f(0,0));
    require(check().accepted,"unselected correspondence incorrectly affects final inlier gate");
    const double nan=std::numeric_limits<double>::quiet_NaN();
    r.at<double>(0,0)=nan;require(!check().accepted,"nonfinite rotation accepted");r=k.clone();
    t.at<double>(0)=nan;require(!check().accepted,"nonfinite translation accepted");t.at<double>(0)=0;
    k.at<double>(0,0)=nan;require(!check().accepted,"nonfinite intrinsics accepted");k.at<double>(0,0)=1;
    image[0].x=std::numeric_limits<float>::quiet_NaN();require(!check().accepted,"nonfinite observed pixel accepted");image[0].x=0;
    object[0].x=std::numeric_limits<float>::quiet_NaN();require(!check().accepted,"nonfinite selected object accepted");object[0].x=0;
    r.at<double>(0,0)=-1;require(!check().accepted,"reflection accepted as rigid rotation");
    r.at<double>(0,0)=1.1;require(!check().accepted,"nonorthogonal transform accepted");
    r=k.clone();cv::Mat rv=cv::Mat::zeros(3,1,CV_64F);
    rv.at<double>(0)=nan;require(!final_geometry::validatePnP(true,object,image,k,rv,t,indices,12).accepted,"nonfinite rvec accepted");
    k.at<double>(0,0)=120;t.at<double>(0)=.1;
    require(!check().accepted,"double 12px solution exceeds boundary after public Float32 conversion");
    k.at<double>(0,0)=1;t.at<double>(0)=0;t.at<double>(2)=-1.+1e-9;
    require(!check().accepted,"positive double depth rounded to public zero depth was accepted");
    t.at<double>(2)=0;t.at<double>(0)=1e40;
    require(!check().accepted,"finite double translation overflowed public Float32 pose");
    std::cout<<"final geometry boundary, finite, rigid and actual selected-index contracts passed\n";
}
int main(int argc,char**argv) {try {cv::setNumThreads(1);if(argc>1 && std::string(argv[1])=="checks") validationChecks();else singlePath(argc>1 && std::string(argv[1])=="akaze");}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;} }
