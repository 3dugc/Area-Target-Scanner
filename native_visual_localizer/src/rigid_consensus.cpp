#include "area_target_runtime.h"
#include "frame_contract.h"
#include "rigid_math.h"
#include <vector>
#include <new>
namespace {
using namespace atc::math;
ATCStatus validateConfig(const ATCRigidConsensusConfigV2* c){
 const auto abi=atc::validatePod(c);if(abi!=ATC_OK)return abi;
 if(!c->minimum_inliers||!c->maximum_candidates||c->maximum_candidates>10000||c->minimum_inliers>c->maximum_candidates||c->reserved||
  !std::isfinite(c->minimum_inlier_ratio)||c->minimum_inlier_ratio<=0||c->minimum_inlier_ratio>1||
  !std::isfinite(c->maximum_translation_m)||c->maximum_translation_m<=0||!std::isfinite(c->maximum_rotation_rad)||c->maximum_rotation_rad<=0)return ATC_INVALID_ARGUMENT;
 return ATC_OK;
}
}
ATCStatus atc_get_default_rigid_consensus_config_v2(ATCRigidConsensusConfigV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;
 out->minimum_inliers=3;out->maximum_candidates=1000;out->minimum_inlier_ratio=.6f;
 out->maximum_translation_m=.25f;out->maximum_rotation_rad=5*3.14159265358979323846/180;return ATC_OK;
}
ATCStatus atc_make_immersal_alignment_candidate_v2(const float* scan,const float* position,const float* q,float* out){
 if(!out)return ATC_INVALID_ARGUMENT;write(identity(),out);
 if(!scan||!position||!q)return ATC_INVALID_ARGUMENT;
 const auto scanFromCamera=read(scan);if(!rigid(scanFromCamera))return ATC_INVALID_ARGUMENT;
 double squared=0;for(int i=0;i<4;++i){if(!std::isfinite(q[i]))return ATC_INVALID_ARGUMENT;squared+=static_cast<double>(q[i])*q[i];}
 const double length=std::sqrt(squared);if(length<=.000001)return ATC_INVALID_ARGUMENT;
 for(int i=0;i<3;++i)if(!std::isfinite(position[i]))return ATC_INVALID_ARGUMENT;
 const double x=q[0]/length,y=q[1]/length,z=q[2]/length,w=q[3]/length;
 Matrix optical=identity();optical[0]=1-2*(y*y+z*z);optical[1]=2*(x*y-w*z);optical[2]=2*(x*z+w*y);
 optical[4]=2*(x*y+w*z);optical[5]=1-2*(x*x+z*z);optical[6]=2*(y*z-w*x);
 optical[8]=2*(x*z-w*y);optical[9]=2*(y*z+w*x);optical[10]=1-2*(x*x+y*y);
 // Right multiply D to normalize only the camera basis, retaining map XYZ.
 for(int row=0;row<3;++row){optical[row*4+1]*=-1;optical[row*4+2]*=-1;optical[row*4+3]=position[row];}
 const auto candidate=multiply(optical,inverse(scanFromCamera));
 return rigid(candidate)&&write(candidate,out)?ATC_OK:ATC_INVALID_ARGUMENT;
}
ATCStatus atc_estimate_rigid_consensus_v2(const ATCRigidConsensusConfigV2* config,const float* candidates,uint32_t count,ATCRigidConsensusResultV2* out){
 const auto abi=atc::validatePod(out);if(abi!=ATC_OK)return abi;
 *out={};out->struct_size=sizeof(*out);out->api_version=ATC_API_VERSION;write(identity(),out->map_from_scan);out->matched_count=count;
 const auto valid=validateConfig(config);if(valid!=ATC_OK)return valid;
 if(count>config->maximum_candidates)return ATC_RESOURCE_LIMIT;
 if(count<config->minimum_inliers){out->rejection_reason=ATC_CONSENSUS_INSUFFICIENT;return ATC_NO_MATCH;}
 if(!candidates){out->rejection_reason=ATC_CONSENSUS_INVALID_TRANSFORM;return ATC_INVALID_ARGUMENT;}
 try{
  std::vector<Matrix> poses;poses.reserve(count);
  for(uint32_t i=0;i<count;++i){const auto m=read(candidates+static_cast<size_t>(i)*16);if(!rigid(m)){out->rejection_reason=ATC_CONSENSUS_INVALID_TRANSFORM;return ATC_INVALID_ARGUMENT;}poses.push_back(m);}
  uint32_t bestIndex=0,bestCount=0;double bestCost=INFINITY,bestTranslation=0,bestRotation=0;
  for(uint32_t i=0;i<count;++i){uint32_t inliers=0;double cost=0,maximumTranslation=0,maximumRotation=0;
   for(uint32_t j=0;j<count;++j){const double translation=residual(poses[i],poses[j]).translation,rotation=quaternionAngle(poses[i],poses[j]);
    if(translation<=config->maximum_translation_m&&rotation<=config->maximum_rotation_rad){++inliers;cost+=translation/config->maximum_translation_m+rotation/config->maximum_rotation_rad;maximumTranslation=std::max(maximumTranslation,translation);maximumRotation=std::max(maximumRotation,rotation);}}
   if(inliers>bestCount||(inliers==bestCount&&cost<bestCost)){bestIndex=i;bestCount=inliers;bestCost=cost;bestTranslation=maximumTranslation;bestRotation=maximumRotation;}
  }
  out->inlier_count=bestCount;out->selected_index=bestIndex;
  if(bestCount<config->minimum_inliers||static_cast<float>(bestCount)/count<config->minimum_inlier_ratio){out->rejection_reason=ATC_CONSENSUS_INCONSISTENT;return ATC_NO_MATCH;}
  // Preserve measured float coefficients exactly, including translation origin.
  std::copy_n(candidates+static_cast<size_t>(bestIndex)*16,16,out->map_from_scan);out->valid=1;
  out->maximum_translation_residual_m=bestTranslation;out->maximum_rotation_residual_rad=bestRotation;return ATC_OK;
 }catch(const std::bad_alloc&){return ATC_RESOURCE_LIMIT;}catch(...){return ATC_INTERNAL_ERROR;}
}
