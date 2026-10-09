#include "visual_localizer.h"
#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/imgproc.hpp>
#include <dlfcn.h>
#include <cstring>
#include <stdexcept>
#include <iostream>
#include <vector>
#include <cstddef>

static void require(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
static_assert(sizeof(VLResult)==76 && sizeof(VLDebugInfo)==48,"legacy ABI sizes changed");
static_assert(offsetof(VLResult,pose)==4 && offsetof(VLResult,confidence)==68,"legacy ABI offsets changed");
struct Native {
    void* library;
    decltype(&vl_create) create;
    decltype(&vl_destroy) destroy;
    decltype(&vl_add_vocabulary_word) word;
    decltype(&vl_add_keyframe) add;
    decltype(&vl_build_index) build;
    decltype(&vl_process_frame_out) process;
    decltype(&vl_reset) reset;
    int (*mode)(VLHandle,int);
    explicit Native(const char* path):library(dlopen(path,RTLD_NOW|RTLD_LOCAL)) {
        require(library!=nullptr,"native library did not load");
#define LOAD(member,symbol) member=reinterpret_cast<decltype(member)>(dlsym(library,#symbol));require(member!=nullptr,"missing " #symbol)
        LOAD(create,vl_create);LOAD(destroy,vl_destroy);LOAD(word,vl_add_vocabulary_word);
        LOAD(add,vl_add_keyframe);LOAD(build,vl_build_index);LOAD(process,vl_process_frame_out);LOAD(reset,vl_reset);
        LOAD(mode,vl_set_recovery_mode);
#undef LOAD
    }
    ~Native(){dlclose(library);}
};
static cv::Mat image(int seed) {cv::RNG rng(seed);cv::Mat m(480,640,CV_8UC1);rng.fill(m,cv::RNG::UNIFORM,0,256);return m;}
static void map(Native& api,VLHandle handle,int id,const cv::Mat& source,bool split) {
    cv::Mat enhanced,desc;cv::createCLAHE(2,{8,8})->apply(source,enhanced);
    std::vector<cv::KeyPoint> kp;cv::ORB::create(3000)->detectAndCompute(enhanced,cv::noArray(),kp,desc);
    std::vector<int> selected;bool cells[16]={};
    for(int i=0;i<desc.rows;++i){const auto p=kp[i].pt;int cell=int(p.y/120)*4+int(p.x/160);
        if(cell>=0&&cell<16&&!cells[cell]){cells[cell]=true;selected.push_back(i);}}
    require(selected.size()==16,"mode fixture requires 16 real image cells");
    const float pose[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    for(int group=0;group<(split?4:1);++group){cv::Mat d;std::vector<float>xyz,xy;
        for(int j=0;j<16;++j)if(!split||j%4==group){const auto p=kp[selected[j]].pt;float z=2.f+.12f*j;
            d.push_back(desc.row(selected[j]));xyz.insert(xyz.end(),{z*(p.x-320)/520,-z*(p.y-240)/515,-z});xy.insert(xy.end(),{p.x,p.y});}
        require(api.add(handle,id+group,pose,d.data,d.rows,xyz.data(),xy.data())==1,"mode fixture map loading failed");}
}
static VLResult run(Native& api,VLHandle handle,const cv::Mat& m) {
    cv::theRNG().state=20261008;VLResult r{};
    api.process(handle,m.data,m.cols,m.rows,520,515,320,240,0,nullptr,&r);return r;
}
int main(int argc,char**argv){try{
    require(argc==2,"usage: recovery_mode_test library");cv::setNumThreads(1);
    Native api(argv[1]);auto joint=image(20261008),original=image(20261009);
    auto standard=api.create(),enhanced=api.create();require(standard&&enhanced,"two native handles required");
    const unsigned char word[32]={};for(auto h:{standard,enhanced}){require(api.word(h,0,word,32,1)==1,"word loading failed");
        map(api,h,10,joint,true);map(api,h,20,original,false);require(api.build(h)==1,"index failed");}
    require(api.mode(nullptr,1)==0 && api.mode(nullptr,0)==0,"null mode handle must fail");
    // Retired process flags cannot turn the default standard handle enhanced.
    setenv("VL_DIAGNOSTIC_SCALED_FALLBACK","1",1);setenv("VL_DIAGNOSTIC_JOINT_POOL","1",1);
    require(run(api,standard,joint).state==2 && run(api,enhanced,joint).state==2,"default mode is affected by global recovery flags");
    require(api.mode(enhanced,1)==1,"enhanced setting failed");
    require(run(api,standard,joint).state==2 && run(api,enhanced,joint).state==1,"mode leaked between two handles or did not enable joint recovery");
    require(api.mode(enhanced,-1)==0 && api.mode(enhanced,2)==0,"invalid modes must fail");
    require(run(api,enhanced,joint).state==1,"invalid mode mutated enhanced choice");
    api.reset(enhanced);api.reset(standard);
    require(run(api,enhanced,joint).state==1 && run(api,standard,joint).state==2,"reset failed to preserve per-handle mode");
    const auto a=run(api,standard,original),b=run(api,enhanced,original);
    require(a.state==1 && std::memcmp(&a,&b,sizeof(a))==0,"enhanced changed original-success bytes");
    require(api.mode(enhanced,0)==1,"standard transition failed");api.reset(enhanced);
    require(run(api,enhanced,joint).state==2,"mode disable or reset failed");
    unsetenv("VL_DIAGNOSTIC_SCALED_FALLBACK");unsetenv("VL_DIAGNOSTIC_JOINT_POOL");
    api.destroy(standard);api.destroy(enhanced);
    std::cout<<"{\"handles\":2,\"default_standard\":true,\"reset_preserves_choice\":true,\"global_recovery_flags_ignored\":true,\"original_success_bytes_preserved\":true}\n";
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
