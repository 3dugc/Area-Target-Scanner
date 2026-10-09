#include "area_target_runtime.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
#define CHECK(c) do{if(!(c))throw std::runtime_error(#c);}while(0)
using Matrix=std::array<float,16>;
static Matrix pose(float x=0,float y=0,float z=0,double degrees=0){Matrix m{1,0,0,x,0,1,0,y,0,0,1,z,0,0,0,1};const double r=degrees*3.14159265358979323846/180;m[0]=m[5]=std::cos(r);m[1]=-std::sin(r);m[4]=std::sin(r);return m;}
static ATCRigidConsensusConfigV2 config(){ATCRigidConsensusConfigV2 c{};c.struct_size=sizeof(c);c.api_version=2;c.minimum_inliers=3;c.maximum_candidates=1000;c.minimum_inlier_ratio=.6f;c.maximum_translation_m=.25f;c.maximum_rotation_rad=5*3.14159265358979323846/180;return c;}
static ATCRigidConsensusResultV2 estimate(const std::vector<Matrix>& p,ATCStatus status=ATC_OK){auto c=config();ATCRigidConsensusResultV2 out{};out.struct_size=sizeof(out);out.api_version=2;CHECK(atc_estimate_rigid_consensus_v2(&c,p.empty()?nullptr:p.front().data(),p.size(),&out)==status);return out;}
static ATCKeyframeCandidateV2 candidate(uint32_t ordinal,float x=0,double rotation=0,float lap=2500,bool posed=true,bool accepted=true){ATCKeyframeCandidateV2 c{};c.struct_size=sizeof(c);c.api_version=2;c.source_ordinal=ordinal;c.pose_valid=posed;c.quality_accepted=accepted;c.laplacian_variance=lap;const auto p=pose(x,0,0,rotation);std::copy(p.begin(),p.end(),c.camera_to_world);return c;}
static std::vector<uint32_t> select(const std::vector<ATCKeyframeCandidateV2>& c,uint32_t count,uint32_t budget){std::vector<uint32_t> out(c.size());uint32_t n=UINT32_MAX;CHECK(atc_select_keyframes_v2(c.data(),c.size(),count,budget,out.data(),out.size(),&n)==ATC_OK);out.resize(n);return out;}
int main(){int passed=0,failed=0;auto test=[&](const char* name,const std::function<void()>& f){try{f();++passed;}catch(const std::exception& e){++failed;std::cerr<<name<<": "<<e.what()<<'\n';}};
 test("capture first reset and minimum cadence",[]{auto previous=pose(),current=pose();uint32_t capture=9;
  CHECK(atc_capture_candidate_v2(0,0,nullptr,current.data(),&capture)==ATC_OK&&capture);
  current=pose(1);CHECK(atc_capture_candidate_v2(199999999,0,previous.data(),current.data(),&capture)==ATC_OK&&!capture);
  CHECK(atc_capture_candidate_v2(200000000,0,previous.data(),current.data(),&capture)==ATC_OK&&capture);
  current=previous;CHECK(atc_capture_candidate_v2(499999999,0,previous.data(),current.data(),&capture)==ATC_OK&&!capture);
  CHECK(atc_capture_candidate_v2(500000000,0,previous.data(),current.data(),&capture)==ATC_OK&&capture);
 });
 test("capture metres rotation and invalid source transforms",[]{auto p=pose(),c=pose(.1f);uint32_t out=0;
  CHECK(atc_capture_candidate_v2(200000000,0,p.data(),c.data(),&out)==ATC_OK&&out);
  c=pose(0,0,0,16);CHECK(atc_capture_candidate_v2(200000000,0,p.data(),c.data(),&out)==ATC_OK&&out);
  c=pose(0,0,0,14);CHECK(atc_capture_candidate_v2(200000000,0,p.data(),c.data(),&out)==ATC_OK&&!out);
  c[0]=2;CHECK(atc_capture_candidate_v2(500000000,0,p.data(),c.data(),&out)==ATC_INVALID_ARGUMENT&&!out);
  c=p;CHECK(atc_capture_candidate_v2(1,2,p.data(),c.data(),&out)==ATC_INVALID_ARGUMENT&&!out);
  CHECK(atc_capture_candidate_v2(1,0,nullptr,c.data(),nullptr)==ATC_INVALID_ARGUMENT);
 });
 test("static consensus core default exact legacy thresholds",[]{static_assert(sizeof(ATCRigidConsensusConfigV2)==32);static_assert(sizeof(ATCRigidConsensusResultV2)==100);auto c=config();c.minimum_inliers=0;CHECK(atc_get_default_rigid_consensus_config_v2(&c)==ATC_OK&&c.minimum_inliers==3&&c.minimum_inlier_ratio==.6f&&c.maximum_translation_m==.25f);});
 test("three measured candidates select center medoid unchanged",[]{std::vector<Matrix> p{pose(2,-1,4,35),pose(1.95f,-1,4,34),pose(2.1f,-1,4,37)};auto out=estimate(p);CHECK(out.valid&&out.inlier_count==3&&out.matched_count==3&&out.selected_index==0);CHECK(std::equal(p[0].begin(),p[0].end(),out.map_from_scan));CHECK(std::fabs(out.maximum_translation_residual_m-.1)<1e-5&&std::fabs(out.maximum_rotation_residual_rad-2*3.14159265358979323846/180)<1e-5);});
 test("sixty percent consensus accepts outliers and rejects split clusters",[]{std::vector<Matrix> p{pose(),pose(.1f),pose(-.1f),pose(20),pose(0,0,0,50)};CHECK(estimate(p).valid);p.push_back(pose(20));CHECK(!estimate(p,ATC_NO_MATCH).valid);p={pose(),pose(.1f),pose(-.1f),pose(20),pose(20.1f),pose(19.9f)};CHECK(!estimate(p,ATC_NO_MATCH).valid);CHECK(estimate({pose(),pose()},ATC_NO_MATCH).rejection_reason==ATC_CONSENSUS_INSUFFICIENT);});
 test("rotation wrap uses shortest arc",[]{auto out=estimate({pose(0,0,0,179),pose(0,0,0,-179),pose(0,0,0,180)});CHECK(out.valid&&out.selected_index==2&&std::fabs(out.maximum_rotation_residual_rad-3.14159265358979323846/180)<1e-5);});
 test("invalid rigidity rejects the entire static calibration",[]{for(int mode=0;mode<5;++mode){auto bad=pose();if(mode==0)bad[0]=std::numeric_limits<float>::quiet_NaN();if(mode==1)bad[0]=2;if(mode==2)bad[1]=.2f;if(mode==3)bad[0]=-1;if(mode==4)bad[12]=.1f;const auto out=estimate({pose(),pose(),bad},ATC_INVALID_ARGUMENT);CHECK(!out.valid&&out.rejection_reason==ATC_CONSENSUS_INVALID_TRANSFORM);}});
 test("SDK candidate converts camera basis only and normalizes quaternion",[]{auto scan=pose(1,2,3);float position[3]{4,5,6},q[4]{0,0,0,2};Matrix out{};CHECK(atc_make_immersal_alignment_candidate_v2(scan.data(),position,q,out.data())==ATC_OK);CHECK(out[0]==1&&out[5]==-1&&out[10]==-1&&out[3]==3&&out[7]==7&&out[11]==9);q[3]=0;CHECK(atc_make_immersal_alignment_candidate_v2(scan.data(),position,q,out.data())==ATC_INVALID_ARGUMENT);});
 test("coverage preserves original source ordinals and clean all-eligible case",[]{static_assert(sizeof(ATCKeyframeCandidateV2)==88);auto selected=select({candidate(4),candidate(1),candidate(3,0,0,100,false,false)},5,0);CHECK(selected==std::vector<uint32_t>({1,4}));});
 test("coverage prefers remote and rotated views within fixed budget",[]{auto selected=select({candidate(0),candidate(1,.05f),candidate(2,.1f),candidate(3,10),candidate(4,0,0,100)},5,2);CHECK(selected==std::vector<uint32_t>({0,3}));selected=select({candidate(0),candidate(1,0,2),candidate(2,0,90)},3,2);CHECK(selected==std::vector<uint32_t>({0,2}));});
 test("coverage malformed pose degrades to temporal and deterministic tie",[]{auto a=candidate(0),b=candidate(5),c=candidate(9);a.camera_to_world[0]=2;b.pose_valid=0;c.pose_valid=0;CHECK(select({a,b,c},10,2)==std::vector<uint32_t>({0,9}));CHECK(select({candidate(2),candidate(1)},3,1)==std::vector<uint32_t>({1}));});
 test("coverage limits duplicates and output capacity are safe",[]{auto a=candidate(0);uint32_t out=123,n=123;CHECK(atc_select_keyframes_v2(&a,1,1,0,&out,0,&n)==ATC_RESOURCE_LIMIT&&n==0&&out==123);const ATCKeyframeCandidateV2 duplicates[2]{a,a};CHECK(atc_select_keyframes_v2(duplicates,2,2,1,&out,1,&n)==ATC_INVALID_ARGUMENT&&n==0);CHECK(atc_select_keyframes_v2(&a,10001,10001,1,&out,1,&n)==ATC_RESOURCE_LIMIT);CHECK(atc_select_keyframes_v2(&a,1,1,81,&out,1,&n)==ATC_RESOURCE_LIMIT);});
 std::cout<<"shared capture/rigid/coverage policies: "<<passed<<" passed, "<<failed<<" failed\n";return failed?1:0;
}
