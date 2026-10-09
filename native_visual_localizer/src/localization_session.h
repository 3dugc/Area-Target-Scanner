#pragma once
#include "area_target_runtime.h"
#include <array>
#include <deque>
namespace atc {
ATCStatus validateSessionConfig(const ATCSessionConfigV2* config);
// Pure numeric synchronous state. One serial owner, no platform clock or worker.
class LocalizationSession {
public:
 explicit LocalizationSession(const ATCSessionConfigV2& config):config_(config){}
 ATCStatus update(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,ATCSessionResultV2& out);
 ATCStatus updateAt(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,uint64_t now,ATCSessionResultV2& out);
 ATCStatus poll(uint64_t now,ATCSessionResultV2& out);
 void reset(uint64_t generation,uint64_t tracking_epoch);
private:
 using Matrix=std::array<double,16>;
 ATCSessionConfigV2 config_;
 bool sequence_bound_=false,generation_pinned_=false,tracking_bound_=false,epoch_pinned_=false;
 uint64_t generation_=0,map_instance_=0,clock_epoch_=0,camera_id_=0;
 uint64_t last_frame_=0,last_capture_=0,tracking_epoch_=0,last_visual_capture_=0;
 uint64_t last_delivery_=0;
 bool delivery_bound_=false,ever_published_=false;
 uint32_t state_=ATC_SESSION_INITIALIZING;
 bool alignment_ready_=false;
 Matrix alignment_{};
 std::deque<Matrix> window_;
 std::deque<uint64_t> window_capture_;
 void clearAlignment(uint32_t state);
 Matrix representative() const;
 void expire(uint64_t now,bool legacy);
 bool deliveryTime(uint64_t now,ATCSessionResultV2& out);
 void held(ATCSessionResultV2& out,const Matrix* world_from_camera=nullptr) const;
 ATCStatus updateCore(const ATCResultV2& raw,const ATCTrackingSampleV2* tracking,uint64_t now,ATCSessionResultV2& out,bool legacy);
};
}
