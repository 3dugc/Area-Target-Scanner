#include "area_target_runtime.h"
#include "frame_contract.h"
#include "rigid_math.h"
#include <algorithm>
#include <cmath>
#include <limits>
ATCStatus atc_assess_gray_quality(const ATCFrameV2* frame,ATCGrayQualityV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
 out->policy_version=ATC_GRAY_QUALITY_POLICY_VERSION;out->rejection_reason=ATC_GRAY_QUALITY_UNREADABLE;
 const auto input=atc::validatePod(frame);if(input!=ATC_OK)return input;
 if(frame->pixel_format!=ATC_PIXEL_FORMAT_GRAY8)return ATC_UNSUPPORTED_FORMAT;
 if(!frame->data||frame->width<3||frame->height<3||frame->row_stride<frame->width)return ATC_INVALID_ARGUMENT;
 const auto cap=atc_default_config_v2();
 if(frame->width>cap.max_dimension||frame->height>cap.max_dimension)return ATC_RESOURCE_LIMIT;
 const uint64_t rows=frame->height-1,maximum=std::numeric_limits<uint64_t>::max();
 if(frame->row_stride>(maximum-frame->width)/rows)return ATC_INVALID_ARGUMENT;
 const uint64_t minimum=rows*frame->row_stride+frame->width;
 if(frame->byte_length<minimum)return ATC_INVALID_ARGUMENT;
 if(frame->byte_length>cap.max_image_bytes||minimum>cap.max_image_bytes||minimum>std::numeric_limits<size_t>::max())return ATC_RESOURCE_LIMIT;

 // At most 160x160 centers. Spatial phases vary independently, and all
 // derivatives use immediate source neighbours, never downsampled pixels.
 // This avoids checker/stripe aliasing without allocating a resized image.
 const uint32_t step=(std::max(frame->width,frame->height)+159)/160;
 uint64_t intensity_count=0,dark=0,bright=0;
 double gray_sum=0,gray_squared=0,lap_sum=0,lap_squared=0;
 const auto pixel=[&](uint32_t x,uint32_t y){return frame->data[static_cast<size_t>(y*frame->row_stride+x)];};
 uint32_t gy=0;
 for(uint32_t base_y=1;base_y+1<frame->height;base_y+=step,++gy){
  uint32_t gx=0;
  for(uint32_t base_x=1;base_x+1<frame->width;base_x+=step,++gx){
   const uint32_t x=std::min(base_x+(gx+gy)%step,frame->width-2);
   const uint32_t y=std::min(base_y+(gx/step+gy)%step,frame->height-2);
   const int center=pixel(x,y),left=pixel(x-1,y),right=pixel(x+1,y),up=pixel(x,y-1),down=pixel(x,y+1);
   for(int value:{center,left,right,up,down}){
    gray_sum+=value;gray_squared+=value*value;dark+=value<=4;bright+=value>=251;++intensity_count;
   }
   const double lap=left+right+up+down-4*center;
   lap_sum+=lap;lap_squared+=lap*lap;++out->sample_count;
  }
 }
 const double mean=gray_sum/intensity_count,lap_mean=lap_sum/out->sample_count;
 out->mean_intensity=static_cast<float>(mean);
 out->gray_standard_deviation=static_cast<float>(std::sqrt(std::max(0.0,gray_squared/intensity_count-mean*mean)));
 out->laplacian_variance=static_cast<float>(std::max(0.0,lap_squared/out->sample_count-lap_mean*lap_mean));
 out->saturated_fraction=static_cast<float>(static_cast<double>(std::max(dark,bright))/intensity_count);
 if(mean<12)out->rejection_reason=ATC_GRAY_QUALITY_TOO_DARK;
 else if(mean>243)out->rejection_reason=ATC_GRAY_QUALITY_TOO_BRIGHT;
 else if(out->saturated_fraction>=.95f)out->rejection_reason=ATC_GRAY_QUALITY_SATURATED;
 else if(out->gray_standard_deviation<6)out->rejection_reason=ATC_GRAY_QUALITY_LOW_TEXTURE;
 else if(out->laplacian_variance<8)out->rejection_reason=ATC_GRAY_QUALITY_BLURRED;
 else {out->accepted=1;out->rejection_reason=ATC_GRAY_QUALITY_ACCEPTED;}
 return ATC_OK;
}

ATCStatus atc_capture_candidate_v2(uint64_t now,uint64_t previousTime,const float* previous,const float* current,uint32_t* out){
 if(!out)return ATC_INVALID_ARGUMENT;*out=0;if(!current)return ATC_INVALID_ARGUMENT;
 const auto currentPose=atc::math::read(current);if(!atc::math::rigid(currentPose))return ATC_INVALID_ARGUMENT;
 if(!previous){*out=1;return ATC_OK;}
 const auto previousPose=atc::math::read(previous);if(!atc::math::rigid(previousPose)||now<previousTime)return ATC_INVALID_ARGUMENT;
 const uint64_t elapsed=now-previousTime;if(elapsed<200000000)return ATC_OK;
 const auto residual=atc::math::residual(previousPose,currentPose);
 *out=elapsed>=500000000||residual.translation>=.10||residual.rotation>=15*3.14159265358979323846/180;return ATC_OK;
}
