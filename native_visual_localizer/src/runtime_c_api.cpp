#include "area_target_runtime.h"
#include "frame_contract.h"
#include "map_loader.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <new>
#include <vector>
namespace {
struct Runtime {
    ATCConfigV2 config;
    std::unique_ptr<VisualLocalizer> localizer;
    uint64_t map_instance=0;
    bool bound=false;
    uint64_t generation=0,clock_epoch=0,camera_id=0,last_frame=0,last_timestamp=0;
    explicit Runtime(const ATCConfigV2& c):config(c){}
    void clearBinding(){bound=false;}
};
std::atomic<uint64_t> next_map_instance{1};
ATCStatus setStatus(ATCResultV2* out,ATCStatus status){out->status=status;return status;}
void clearResult(ATCResultV2* out){
    *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
    out->camera_from_scan[0]=out->camera_from_scan[5]=out->camera_from_scan[10]=out->camera_from_scan[15]=1;
}
void frameIdentity(const ATCFrameV2& f,ATCResultV2* out){
    out->frame_id=f.frame_id;out->capture_timestamp_ns=f.capture_timestamp_ns;
    out->map_generation=f.map_generation;out->capture_clock_epoch=f.capture_clock_epoch;out->camera_id=f.camera_id;
}
}
uint32_t atc_get_api_version(void){return ATC_API_VERSION;}
ATCStatus atc_create(const ATCConfigV2* config,ATCHandle* out_handle){
    if(!out_handle)return ATC_INVALID_ARGUMENT;
    *out_handle=nullptr;
    const auto status=atc::validateConfig(config);if(status!=ATC_OK)return status;
    try{*out_handle=new Runtime(*config);return ATC_OK;}
    catch(const std::bad_alloc&){return ATC_RESOURCE_LIMIT;}catch(...){return ATC_INTERNAL_ERROR;}
}
ATCStatus atc_load_map(ATCHandle handle,const char* directory,ATCMapInfoV2* out){
    const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
    *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
    if(!handle || !directory || !*directory)return ATC_INVALID_ARGUMENT;
    try{
        auto* r=static_cast<Runtime*>(handle);
        auto candidate=atc::loadMap(directory,r->config);
        if(candidate.status!=ATC_OK)return candidate.status;
        if(!candidate.localizer)return ATC_INTERNAL_ERROR;
        const uint64_t id=next_map_instance.fetch_add(1,std::memory_order_relaxed);
        if(!id)return ATC_INTERNAL_ERROR;
        r->localizer=std::move(candidate.localizer);r->map_instance=id;r->clearBinding();
        *out=candidate.info;out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;out->map_instance_id=id;
        return ATC_OK;
    }catch(const std::bad_alloc&){return ATC_RESOURCE_LIMIT;}catch(...){return ATC_INTERNAL_ERROR;}
}
ATCStatus atc_localize(ATCHandle handle,const ATCFrameV2* frame,ATCResultV2* out){
    const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
    clearResult(out);
    if(!handle)return setStatus(out,ATC_INVALID_ARGUMENT);
    auto* r=static_cast<Runtime*>(handle);
    const auto valid=atc::validateFrame(frame,r->config);
    if(atc::validatePod(frame)==ATC_OK)frameIdentity(*frame,out);
    if(valid!=ATC_OK)return setStatus(out,valid);
    out->map_instance_id=r->map_instance;
    if(!r->localizer)return setStatus(out,ATC_MAP_NOT_LOADED);
    if(r->bound && (r->generation!=frame->map_generation || r->clock_epoch!=frame->capture_clock_epoch ||
                   r->camera_id!=frame->camera_id || frame->frame_id<=r->last_frame ||
                   frame->capture_timestamp_ns<=r->last_timestamp))return setStatus(out,ATC_STALE_FRAME);
    try{
        const uint8_t* pixels=frame->data;
        std::vector<uint8_t> packed;
        if(frame->row_stride!=frame->width){
            packed.resize(static_cast<size_t>(frame->width)*frame->height);
            for(uint32_t y=0;y<frame->height;++y)
                std::memcpy(packed.data()+static_cast<size_t>(y)*frame->width,
                            frame->data+static_cast<size_t>(y)*frame->row_stride,frame->width);
            pixels=packed.data();
        }
        // Accepted frames advance identity even on NO_MATCH or processing error.
        r->bound=true;r->generation=frame->map_generation;r->clock_epoch=frame->capture_clock_epoch;
        r->camera_id=frame->camera_id;r->last_frame=frame->frame_id;r->last_timestamp=frame->capture_timestamp_ns;
        const auto legacy=r->localizer->processFrame(pixels,static_cast<int>(frame->width),
            static_cast<int>(frame->height),frame->fx,frame->fy,frame->cx,frame->cy,false,nullptr);
        if(legacy.state!=1)return setStatus(out,ATC_NO_MATCH);
        // D^-1 = D maps legacy AR camera coordinates to optical camera axes.
        for(int i=0;i<16;++i)out->camera_from_scan[i]=((i/4==1 || i/4==2)?-1.f:1.f)*legacy.pose[i];
        out->raw_pose_valid=1;out->inliers=static_cast<uint32_t>(legacy.matched_features);out->confidence=legacy.confidence;
        const auto metric=r->localizer->getReprojectionMetric();
        out->reprojection_error_valid=metric.valid?1:0;out->reprojection_rmse_px=metric.rmse_px;
        return setStatus(out,ATC_OK);
    }catch(const std::bad_alloc&){return setStatus(out,ATC_RESOURCE_LIMIT);}catch(...){return setStatus(out,ATC_INTERNAL_ERROR);}
}
ATCStatus atc_reset(ATCHandle handle){
    if(!handle)return ATC_INVALID_ARGUMENT;
    try{auto* r=static_cast<Runtime*>(handle);if(r->localizer)r->localizer->reset();r->clearBinding();return ATC_OK;}
    catch(...){return ATC_INTERNAL_ERROR;}
}
void atc_destroy(ATCHandle* handle){
    if(!handle || !*handle)return;
    auto* owned=static_cast<Runtime*>(*handle);*handle=nullptr;
    try{delete owned;}catch(...){ /* Exception firewall, destructor is noexcept. */ }
}
