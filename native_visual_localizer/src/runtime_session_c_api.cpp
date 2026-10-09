#include "area_target_runtime.h"
#include "frame_contract.h"
#include "localization_session.h"
#include <new>
namespace {
void clear(ATCSessionResultV2* out){
 *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
 out->camera_from_scan[0]=out->camera_from_scan[5]=out->camera_from_scan[10]=out->camera_from_scan[15]=1;
 out->world_from_scan[0]=out->world_from_scan[5]=out->world_from_scan[10]=out->world_from_scan[15]=1;
}
ATCStatus error(ATCSessionResultV2* out,ATCStatus status){out->status=status;return status;}
ATCStatus exception(ATCSessionResultV2* out,ATCStatus status){out->raw_pose_valid=out->alignment_valid=out->propagated_pose_valid=0;out->mode=ATC_MODE_NONE;return error(out,status);}
}
ATCStatus atc_session_create(const ATCSessionConfigV2* config,ATCSessionHandle* out_handle){
 if(!out_handle)return ATC_INVALID_ARGUMENT;*out_handle=nullptr;
 const auto valid=atc::validateSessionConfig(config);if(valid!=ATC_OK)return valid;
 try{*out_handle=new atc::LocalizationSession(*config);return ATC_OK;}
 catch(const std::bad_alloc&){return ATC_RESOURCE_LIMIT;}catch(...){return ATC_INTERNAL_ERROR;}
}
ATCStatus atc_session_update(ATCSessionHandle handle,const ATCResultV2* raw,const ATCTrackingSampleV2* tracking,ATCSessionResultV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 clear(out);if(!handle)return error(out,ATC_INVALID_ARGUMENT);
 const auto valid=atc::validatePod(raw);if(valid!=ATC_OK){out->rejection_reason=ATC_REJECTION_INVALID_RAW;return error(out,valid);}
 try{return static_cast<atc::LocalizationSession*>(handle)->update(*raw,tracking,*out);}
 catch(const std::bad_alloc&){return exception(out,ATC_RESOURCE_LIMIT);}catch(...){return exception(out,ATC_INTERNAL_ERROR);}
}
ATCStatus atc_get_default_session_config_v2(ATCSessionConfigV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
 out->window_size=out->initialization_samples=out->recovery_samples=2;
 out->max_translation_residual_m=.25f;out->max_rotation_residual_rad=5*3.14159265358979323846/180;
 out->max_pose_skew_ns=50000000;out->max_alignment_age_ns=out->max_result_age_ns=3000000000;
 out->smoothing_tau_seconds=2;return ATC_OK;
}
ATCStatus atc_session_update_at(ATCSessionHandle handle,const ATCResultV2* raw,const ATCTrackingSampleV2* tracking,uint64_t now,ATCSessionResultV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 clear(out);if(!handle)return error(out,ATC_INVALID_ARGUMENT);
 const auto valid=atc::validatePod(raw);
 try{
  auto* session=static_cast<atc::LocalizationSession*>(handle);
  if(valid!=ATC_OK){const auto polled=session->poll(now,*out);if(polled<0)return polled;out->rejection_reason=ATC_REJECTION_INVALID_RAW;return error(out,valid);}
  return session->updateAt(*raw,tracking,now,*out);
 }
 catch(const std::bad_alloc&){return exception(out,ATC_RESOURCE_LIMIT);}catch(...){return exception(out,ATC_INTERNAL_ERROR);}
}
ATCStatus atc_session_poll(ATCSessionHandle handle,uint64_t now,ATCSessionResultV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;clear(out);
 if(!handle)return error(out,ATC_INVALID_ARGUMENT);
 try{return static_cast<atc::LocalizationSession*>(handle)->poll(now,*out);}
 catch(const std::bad_alloc&){return exception(out,ATC_RESOURCE_LIMIT);}catch(...){return exception(out,ATC_INTERNAL_ERROR);}
}
ATCStatus atc_session_reset(ATCSessionHandle handle,uint64_t generation,uint64_t tracking_epoch){
 if(!handle)return ATC_INVALID_ARGUMENT;
 try{static_cast<atc::LocalizationSession*>(handle)->reset(generation,tracking_epoch);return ATC_OK;}
 catch(...){return ATC_INTERNAL_ERROR;}
}
void atc_session_destroy(ATCSessionHandle* handle){
 if(!handle||!*handle)return;auto* owned=static_cast<atc::LocalizationSession*>(*handle);*handle=nullptr;
 try{delete owned;}catch(...){ /* void exception firewall */ }
}
