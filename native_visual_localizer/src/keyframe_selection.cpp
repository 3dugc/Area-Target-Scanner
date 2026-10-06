#include "area_target_runtime.h"
#include "frame_contract.h"
#include "rigid_math.h"
#include <vector>
#include <unordered_set>
#include <new>
namespace {
using namespace atc::math;
struct Candidate {uint32_t ordinal;bool posed;double score;Matrix pose;};
double distance(const Candidate& a,const Candidate& b,uint32_t sourceCount){
 const double temporal=std::fabs(static_cast<double>(a.ordinal)-b.ordinal)/std::max(1u,sourceCount-1);
 if(!a.posed||!b.posed)return temporal;
 const auto difference=residual(a.pose,b.pose);
 return std::min(3.0,difference.translation)+std::min(3.0,difference.rotation/(3.14159265358979323846/6))+.01*temporal;
}
}
ATCStatus atc_select_keyframes_v2(const ATCKeyframeCandidateV2* candidates,uint32_t count,uint32_t sourceCount,uint32_t budget,uint32_t* ordinals,uint32_t capacity,uint32_t* selectedCount){
 if(!selectedCount)return ATC_INVALID_ARGUMENT;*selectedCount=0;
 if(count>10000||budget>80)return ATC_RESOURCE_LIMIT;
 if((count&&!candidates)||count>sourceCount)return ATC_INVALID_ARGUMENT;
 try{
  std::vector<Candidate> eligible;eligible.reserve(count);std::unordered_set<uint32_t> seen;
  for(uint32_t i=0;i<count;++i){const auto& c=candidates[i];const auto abi=atc::validatePod(&c);if(abi!=ATC_OK)return abi;
   if(c.struct_size!=sizeof(c)||c.source_ordinal>=sourceCount||!seen.insert(c.source_ordinal).second||c.pose_valid>1||c.quality_accepted>1)return ATC_INVALID_ARGUMENT;
   if(!c.quality_accepted)continue;
   if(!std::isfinite(c.laplacian_variance)||c.laplacian_variance<0)return ATC_INVALID_ARGUMENT;
   const auto matrix=read(c.camera_to_world);
   eligible.push_back({c.source_ordinal,c.pose_valid==1&&rigid(matrix),std::min(1.0,std::sqrt(static_cast<double>(c.laplacian_variance))/50),matrix});
  }
  const size_t required=budget?std::min<size_t>(eligible.size(),budget):eligible.size();
  if(capacity<required)return ATC_RESOURCE_LIMIT;if(required&&!ordinals)return ATC_INVALID_ARGUMENT;
  std::vector<uint32_t> result;result.reserve(required);
  if(required==eligible.size()){for(const auto& c:eligible)result.push_back(c.ordinal);}
  else if(required){
   std::vector<bool> chosen(eligible.size(),false);std::vector<double> minimum(eligible.size(),INFINITY);
   size_t first=0;
   for(size_t i=1;i<eligible.size();++i)if(eligible[i].score>eligible[first].score||(eligible[i].score==eligible[first].score&&eligible[i].ordinal<eligible[first].ordinal))first=i;
   size_t selected=first;
   for(size_t n=0;n<required;++n){chosen[selected]=true;result.push_back(eligible[selected].ordinal);
    for(size_t i=0;i<eligible.size();++i)if(!chosen[i])minimum[i]=std::min(minimum[i],distance(eligible[i],eligible[selected],sourceCount));
    size_t next=eligible.size();double maximum=-INFINITY;
    for(size_t i=0;i<eligible.size();++i)if(!chosen[i]){const double value=minimum[i]+.05*eligible[i].score;if(value>maximum||(value==maximum&&(next==eligible.size()||eligible[i].ordinal<eligible[next].ordinal))){maximum=value;next=i;}}
    selected=next;
   }
  }
  std::sort(result.begin(),result.end());std::copy(result.begin(),result.end(),ordinals);*selectedCount=result.size();return ATC_OK;
 }catch(const std::bad_alloc&){return ATC_RESOURCE_LIMIT;}catch(...){return ATC_INTERNAL_ERROR;}
}
