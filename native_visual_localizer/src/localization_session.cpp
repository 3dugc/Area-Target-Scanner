#include "localization_session.h"
#include "frame_contract.h"
#include "rigid_math.h"
#include <algorithm>
#include <cmath>
#include <limits>
namespace atc {
namespace {
using namespace math;
ATCStatus finish(ATCSessionResultV2& out,ATCStatus status){out.status=status;return status;}
bool knownStatus(ATCStatus status){return status>=ATC_UNSUPPORTED_FORMAT&&status<=ATC_NO_MATCH;}
ATCStatus validateRaw(const ATCResultV2& r){
 if(!knownStatus(r.status)||r.raw_pose_valid>1||r.reprojection_error_valid>1)return ATC_INVALID_ARGUMENT;
 if(r.status<0){if(r.raw_pose_valid)return ATC_INVALID_ARGUMENT;return r.status;}
 if((r.status==ATC_OK)!=(r.raw_pose_valid==1))return ATC_INVALID_ARGUMENT;
 if(!std::isfinite(r.confidence)||r.confidence<0||r.confidence>1)return ATC_INVALID_ARGUMENT;
 if(r.reprojection_error_valid&&(!std::isfinite(r.reprojection_rmse_px)||r.reprojection_rmse_px<0))return ATC_INVALID_ARGUMENT;
 if(r.raw_pose_valid&&!rigid(read(r.camera_from_scan)))return ATC_INVALID_ARGUMENT;
 return ATC_OK;
}
void identityFields(const ATCResultV2& raw,ATCSessionResultV2& out){
 out.frame_id=raw.frame_id;out.capture_timestamp_ns=raw.capture_timestamp_ns;out.map_generation=raw.map_generation;
 out.capture_clock_epoch=raw.capture_clock_epoch;out.camera_id=raw.camera_id;out.map_instance_id=raw.map_instance_id;
}
}
ATCStatus validateSessionConfig(const ATCSessionConfigV2* c){
 const auto abi=validatePod(c);if(abi!=ATC_OK)return abi;
 if(!c->window_size||!c->initialization_samples||!c->recovery_samples||c->initialization_samples>c->window_size||c->recovery_samples>c->window_size||
  !std::isfinite(c->max_translation_residual_m)||c->max_translation_residual_m<=0||!std::isfinite(c->max_rotation_residual_rad)||c->max_rotation_residual_rad<=0||
  !c->max_pose_skew_ns||!c->max_alignment_age_ns||!c->max_result_age_ns||!std::isfinite(c->smoothing_tau_seconds)||c->smoothing_tau_seconds<0)return ATC_INVALID_ARGUMENT;
 return ATC_OK;
}
void LocalizationSession::clearAlignment(uint32_t state){window_.clear();window_capture_.clear();alignment_ready_=false;alignment_=identity();last_visual_capture_=0;state_=state;}
void LocalizationSession::reset(uint64_t generation,uint64_t epoch){
 clearAlignment(ATC_SESSION_INITIALIZING);sequence_bound_=false;generation_pinned_=true;generation_=generation;
 map_instance_=clock_epoch_=camera_id_=last_frame_=last_capture_=0;
 tracking_bound_=true;epoch_pinned_=true;tracking_epoch_=epoch;delivery_bound_=false;last_delivery_=0;ever_published_=false;
}
LocalizationSession::Matrix LocalizationSession::representative()const{
 // Preserve the existing tracker's medoid policy: choose an actual accepted
 // rigid sample nearest its translation centroid, rather than average matrices.
 std::array<double,3> center{};for(const auto& m:window_)for(int i=0;i<3;++i)center[i]+=m[i*4+3];for(auto& value:center)value/=window_.size();
 double minimum=std::numeric_limits<double>::infinity();const Matrix* selected=&window_.front();
 for(const auto& m:window_){double squared=0;for(int i=0;i<3;++i){const double delta=m[i*4+3]-center[i];squared+=delta*delta;}if(squared<minimum){minimum=squared;selected=&m;}}
 return *selected;
}
void LocalizationSession::expire(uint64_t now,bool legacy){
 if(!legacy)while(!window_capture_.empty()&&now>=window_capture_.front()&&now-window_capture_.front()>config_.max_result_age_ns){window_.pop_front();window_capture_.pop_front();}
 if(alignment_ready_&&now>=last_visual_capture_&&now-last_visual_capture_>config_.max_alignment_age_ns){
  if(legacy){clearAlignment(ATC_SESSION_LOST);return;}
  alignment_ready_=false;alignment_=identity();last_visual_capture_=0;state_=window_.empty()?ATC_SESSION_LOST:ATC_SESSION_CANDIDATE;
 }
 if(!alignment_ready_&&window_.empty()&&state_==ATC_SESSION_CANDIDATE)state_=ever_published_?ATC_SESSION_LOST:ATC_SESSION_INITIALIZING;
}
bool LocalizationSession::deliveryTime(uint64_t now,ATCSessionResultV2& out){
 if(delivery_bound_&&now<last_delivery_){clearAlignment(ATC_SESSION_LOST);out.state=state_;out.rejection_reason=ATC_REJECTION_DELIVERY_CLOCK;return false;}
 delivery_bound_=true;last_delivery_=now;return true;
}
void LocalizationSession::held(ATCSessionResultV2& out,const Matrix* worldFromCamera)const{
 if(!alignment_ready_)return;
 if(!write(alignment_,out.world_from_scan))return;
 out.alignment_valid=1;out.mode=ATC_MODE_PROPAGATED;
 if(worldFromCamera&&!out.raw_pose_valid){const auto predicted=multiply(inverse(*worldFromCamera),alignment_);if(rigid(predicted)&&write(predicted,out.camera_from_scan))out.propagated_pose_valid=1;}
}
ATCStatus LocalizationSession::poll(uint64_t now,ATCSessionResultV2& out){
 out.frame_id=last_frame_;out.capture_timestamp_ns=last_capture_;out.map_generation=generation_;out.map_instance_id=map_instance_;
 out.capture_clock_epoch=clock_epoch_;out.camera_id=camera_id_;out.tracking_epoch=tracking_epoch_;out.state=state_;
 if(!deliveryTime(now,out))return finish(out,ATC_INVALID_ARGUMENT);
 expire(now,false);out.state=state_;
 if(alignment_ready_){out.alignment_age_ns=now-last_visual_capture_;held(out);}
 else if(ever_published_)out.rejection_reason=ATC_REJECTION_ALIGNMENT_AGE;
 return finish(out,ATC_NO_MATCH);
}
ATCStatus LocalizationSession::update(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,ATCSessionResultV2& out){
 return updateCore(raw,tracking,raw.capture_timestamp_ns,out,true);
}
ATCStatus LocalizationSession::updateAt(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,uint64_t now,ATCSessionResultV2& out){
 return updateCore(raw,tracking,now,out,false);
}
ATCStatus LocalizationSession::updateCore(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,uint64_t now,ATCSessionResultV2& out,bool legacy){
 identityFields(raw,out);out.state=state_;out.tracking_epoch=tracking_bound_?tracking_epoch_:0;
 const bool wrongIdentity=(generation_pinned_&&raw.map_generation!=generation_)||(sequence_bound_&&
  (raw.map_generation!=generation_||raw.map_instance_id!=map_instance_||raw.capture_clock_epoch!=clock_epoch_||raw.camera_id!=camera_id_));
 // A foreign map/clock/camera must not label this Session's alignment, nor
 // mutate its delivery clock. Same-identity ordering failures may hold it.
 if(!legacy&&wrongIdentity){out.rejection_reason=ATC_REJECTION_STALE_FRAME;return finish(out,ATC_STALE_FRAME);}
 if(!legacy){
  if(!deliveryTime(now,out))return finish(out,ATC_INVALID_ARGUMENT);
  expire(now,false);
  if(alignment_ready_)out.alignment_age_ns=now-last_visual_capture_;
 }
 const auto valid=validateRaw(raw);
 if(valid!=ATC_OK){if(!legacy)held(out);out.state=state_;out.rejection_reason=ATC_REJECTION_INVALID_RAW;return finish(out,valid);}
 if(!legacy){
  if(now<raw.capture_timestamp_ns){clearAlignment(ATC_SESSION_LOST);out.state=state_;out.rejection_reason=ATC_REJECTION_DELIVERY_CLOCK;return finish(out,ATC_INVALID_ARGUMENT);}
  if(now-raw.capture_timestamp_ns>config_.max_result_age_ns){held(out);out.state=state_;out.rejection_reason=ATC_REJECTION_RESULT_AGE;return finish(out,ATC_STALE_FRAME);}
 }
 if(wrongIdentity||(sequence_bound_&&(raw.frame_id<=last_frame_||raw.capture_timestamp_ns<=last_capture_))){
  if(!legacy)held(out);out.state=state_;out.rejection_reason=ATC_REJECTION_STALE_FRAME;return finish(out,ATC_STALE_FRAME);
 }
 sequence_bound_=true;generation_=raw.map_generation;map_instance_=raw.map_instance_id;clock_epoch_=raw.capture_clock_epoch;camera_id_=raw.camera_id;
 last_frame_=raw.frame_id;last_capture_=raw.capture_timestamp_ns;
 out.raw_pose_valid=raw.raw_pose_valid;if(raw.raw_pose_valid){std::copy_n(raw.camera_from_scan,16,out.camera_from_scan);out.mode=ATC_MODE_RAW;}
 const bool hadAlignment=alignment_ready_;
 if(legacy)expire(now,true);
 const bool expired=hadAlignment&&!alignment_ready_;
 if(alignment_ready_)out.alignment_age_ns=now-last_visual_capture_;
 if(!legacy&&!raw.raw_pose_valid){window_.clear();window_capture_.clear();state_=alignment_ready_?ATC_SESSION_DEGRADED:(ever_published_?ATC_SESSION_LOST:ATC_SESSION_INITIALIZING);}
 auto reject=[&](uint32_t reason,ATCStatus status){if(!legacy)held(out);out.rejection_reason=reason;out.state=state_;return finish(out,status);};
 if(!tracking)return reject(expired?ATC_REJECTION_ALIGNMENT_AGE:ATC_REJECTION_NO_TRACKING,raw.status);
 const auto abi=validatePod(tracking);if(abi!=ATC_OK)return reject(ATC_REJECTION_TRACKING_INVALID,abi);
 if(tracking->frame_id!=raw.frame_id||tracking->capture_timestamp_ns!=raw.capture_timestamp_ns||tracking->map_generation!=raw.map_generation||tracking->capture_clock_epoch!=raw.capture_clock_epoch||tracking->camera_id!=raw.camera_id)return reject(ATC_REJECTION_IDENTITY,raw.status);
 if(tracking_bound_&&tracking->tracking_epoch!=tracking_epoch_){
  if(epoch_pinned_)return reject(ATC_REJECTION_IDENTITY,raw.status);
  clearAlignment(ATC_SESSION_INITIALIZING);out.state=state_;out.alignment_age_ns=0;ever_published_=false;
 }
 tracking_bound_=true;tracking_epoch_=tracking->tracking_epoch;out.tracking_epoch=tracking_epoch_;
 if(tracking->clock_mapping_valid>1||tracking->pose_valid>1||tracking->extrinsics_valid>1||tracking->tracking_quality>ATC_TRACKING_QUALITY_NORMAL)return reject(ATC_REJECTION_TRACKING_INVALID,ATC_INVALID_ARGUMENT);
 if(!tracking->clock_mapping_valid)return reject(ATC_REJECTION_CLOCK_MAPPING,raw.status);
 const auto worldFromCamera=read(tracking->world_from_camera);
 if(!tracking->pose_valid||!tracking->extrinsics_valid||tracking->tracking_quality!=ATC_TRACKING_QUALITY_NORMAL||!rigid(worldFromCamera))return reject(ATC_REJECTION_TRACKING_INVALID,raw.status);
 const uint64_t skew=tracking->pose_timestamp_ns>raw.capture_timestamp_ns?tracking->pose_timestamp_ns-raw.capture_timestamp_ns:raw.capture_timestamp_ns-tracking->pose_timestamp_ns;
 if(skew>config_.max_pose_skew_ns)return reject(ATC_REJECTION_POSE_SKEW,raw.status);
 if(!raw.raw_pose_valid){
  if(!alignment_ready_)return reject(expired?ATC_REJECTION_ALIGNMENT_AGE:ATC_REJECTION_NONE,raw.status);
  held(out,&worldFromCamera);out.state=state_;return finish(out,raw.status);
 }
 const auto candidate=multiply(worldFromCamera,read(raw.camera_from_scan));
 float finiteCheck[16];if(!rigid(candidate)||!write(candidate,finiteCheck))return reject(ATC_REJECTION_TRACKING_INVALID,raw.status);
 const auto consistent=[&](const Matrix& a,const Matrix& b){const auto d=residual(a,b);return d.translation<=config_.max_translation_residual_m&&d.rotation<=config_.max_rotation_residual_rad;};
 if(legacy){
  if(!window_.empty()&&!consistent(representative(),candidate)){
   if(!alignment_ready_){window_.clear();window_capture_.clear();window_.push_back(candidate);window_capture_.push_back(raw.capture_timestamp_ns);}
   return reject(ATC_REJECTION_OUTLIER,raw.status);
  }
 }else if(alignment_ready_&&consistent(alignment_,candidate)){
  window_.clear();window_capture_.clear();
  auto selected=candidate;
  if(config_.smoothing_tau_seconds>0){const double seconds=static_cast<double>(raw.capture_timestamp_ns-last_visual_capture_)*1e-9;selected=interpolate(alignment_,candidate,-std::expm1(-seconds/config_.smoothing_tau_seconds));}
  alignment_=selected;last_visual_capture_=raw.capture_timestamp_ns;state_=ATC_SESSION_TRACKING;
  write(alignment_,out.world_from_scan);out.alignment_valid=1;out.mode=ATC_MODE_ALIGNED;out.alignment_age_ns=now-last_visual_capture_;out.state=state_;return finish(out,raw.status);
 }else if(std::any_of(window_.begin(),window_.end(),[&](const Matrix& previous){return !consistent(previous,candidate);})){
  window_.clear();window_capture_.clear();
 }
 window_.push_back(candidate);window_capture_.push_back(raw.capture_timestamp_ns);if(window_.size()>config_.window_size){window_.pop_front();window_capture_.pop_front();}
 const uint32_t required=legacy?(state_==ATC_SESSION_LOST?config_.recovery_samples:config_.initialization_samples):(ever_published_?config_.recovery_samples:config_.initialization_samples);
 if(!alignment_ready_&&window_.size()<required){if(!legacy)state_=ATC_SESSION_CANDIDATE;out.state=state_;return finish(out,raw.status);}
 if(!legacy&&alignment_ready_&&window_.size()<required){state_=ATC_SESSION_DEGRADED;held(out);return reject(ATC_REJECTION_OUTLIER,raw.status);}
 auto selected=legacy?representative():window_.back();
 if(legacy&&alignment_ready_&&config_.smoothing_tau_seconds>0){
  const double seconds=static_cast<double>(raw.capture_timestamp_ns-last_visual_capture_)*1e-9;
  selected=interpolate(alignment_,selected,-std::expm1(-seconds/config_.smoothing_tau_seconds));
 }
 alignment_=selected;alignment_ready_=ever_published_=true;last_visual_capture_=raw.capture_timestamp_ns;state_=ATC_SESSION_TRACKING;
 if(!legacy){window_.clear();window_capture_.clear();}
 if(!write(alignment_,out.world_from_scan))return reject(ATC_REJECTION_TRACKING_INVALID,raw.status);
 out.alignment_valid=1;out.mode=ATC_MODE_ALIGNED;out.alignment_age_ns=legacy?0:now-last_visual_capture_;out.state=state_;return finish(out,raw.status);
}
}
