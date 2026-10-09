#include "visual_localizer.h"
#include "area_target_runtime.h"
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <type_traits>
#define CHECK(c) do { if (!(c)) throw std::runtime_error(#c); } while (0)
#define PREFIX(T) static_assert(offsetof(T, struct_size)==0 && offsetof(T, api_version)==4); static_assert(std::is_standard_layout<T>::value)
static_assert(sizeof(VLResult)==76 && sizeof(VLDebugInfo)==48);
PREFIX(ATCConfigV2); PREFIX(ATCFrameV2); PREFIX(ATCMapInfoV2); PREFIX(ATCResultV2);
PREFIX(ATCSessionConfigV2); PREFIX(ATCTrackingSampleV2); PREFIX(ATCSessionResultV2);
PREFIX(ATCGrayQualityV2); PREFIX(ATCRigidConsensusConfigV2); PREFIX(ATCRigidConsensusResultV2); PREFIX(ATCKeyframeCandidateV2);
static_assert(sizeof(ATCRigidConsensusConfigV2)==32 && sizeof(ATCRigidConsensusResultV2)==100 && sizeof(ATCKeyframeCandidateV2)==88);
static_assert(sizeof(decltype(ATCFrameV2::frame_id))==8);
static_assert(sizeof(decltype(ATCFrameV2::row_stride))==8);
static_assert(sizeof(decltype(ATCFrameV2::width))==4);
static_assert(sizeof(ATCStatus)==4);
static_assert(sizeof(decltype(ATCResultV2::camera_from_scan))==16*4);
#if INTPTR_MAX == INT64_MAX
static_assert(sizeof(ATCConfigV2)==88 && sizeof(ATCFrameV2)==104 && sizeof(ATCMapInfoV2)==56);
static_assert(sizeof(ATCResultV2)==144 && sizeof(ATCTrackingSampleV2)==144);
static_assert(sizeof(ATCSessionConfigV2)==64 && sizeof(ATCSessionResultV2)==232);
static_assert(offsetof(ATCFrameV2,data)==48 && offsetof(ATCFrameV2,fx)==84);
static_assert(offsetof(ATCResultV2,camera_from_scan)==64);
static_assert(offsetof(ATCTrackingSampleV2,world_from_camera)==80);
static_assert(offsetof(ATCSessionResultV2,world_from_scan)==168);
#endif
int main() {
  try {
    CHECK(atc_get_api_version()==2);
    ATCConfigV2 config=atc_default_config_v2();
    CHECK(config.max_database_bytes==UINT64_C(512)*1024*1024);
    CHECK(config.max_keyframes==1000 && config.max_vocabulary_words==4096);
    CHECK(config.max_total_features==200000 && config.max_orb_features_per_keyframe==2000);
    CHECK(config.max_akaze_features_per_keyframe==8192 && config.max_bow_products==200000000);
    ATCHandle h=nullptr, h2=nullptr;
    CHECK(atc_create(&config,&h)==ATC_OK && h);
    CHECK(atc_create(&config,&h2)==ATC_OK && h2 && h2!=h);
    auto bad=config; bad.api_version=1; ATCHandle no=reinterpret_cast<void*>(1);
    CHECK(atc_create(&bad,&no)==ATC_ABI_MISMATCH && no==nullptr);
    bad=config; bad.max_sql_steps=0;
    CHECK(atc_create(&bad,&no)==ATC_INVALID_ARGUMENT && no==nullptr);
    bad=config; ++bad.max_database_bytes;
    CHECK(atc_create(&bad,&no)==ATC_INVALID_ARGUMENT && no==nullptr);
    bad=config; bad.map_coordinate_policy=99;
    CHECK(atc_create(&bad,&no)==ATC_INVALID_ARGUMENT && no==nullptr);
    struct Guard { uint32_t size=8; uint32_t version=2; unsigned char tail[64]; } guard;
    std::memset(guard.tail,0xA5,sizeof(guard.tail));
    CHECK(atc_localize(h,nullptr,reinterpret_cast<ATCResultV2*>(&guard))==ATC_ABI_MISMATCH);
    for (auto c: guard.tail) CHECK(c==0xA5);
    CHECK(atc_get_default_session_config_v2(reinterpret_cast<ATCSessionConfigV2*>(&guard))==ATC_ABI_MISMATCH);
    CHECK(atc_get_default_rigid_consensus_config_v2(reinterpret_cast<ATCRigidConsensusConfigV2*>(&guard))==ATC_ABI_MISMATCH);
    CHECK(atc_estimate_rigid_consensus_v2(nullptr,nullptr,0,reinterpret_cast<ATCRigidConsensusResultV2*>(&guard))==ATC_ABI_MISMATCH);
    CHECK(atc_session_update_at(nullptr,nullptr,nullptr,0,reinterpret_cast<ATCSessionResultV2*>(&guard))==ATC_ABI_MISMATCH);
    CHECK(atc_session_poll(nullptr,0,reinterpret_cast<ATCSessionResultV2*>(&guard))==ATC_ABI_MISMATCH);
    for (auto c: guard.tail) CHECK(c==0xA5);
    struct ExtendedConsensus {ATCRigidConsensusResultV2 value{};unsigned char tail[32];} extended;
    extended.value.struct_size=sizeof(extended);extended.value.api_version=2;std::memset(extended.tail,0x5A,sizeof(extended.tail));
    ATCRigidConsensusConfigV2 consensus{};consensus.struct_size=sizeof(consensus);consensus.api_version=2;
    CHECK(atc_get_default_rigid_consensus_config_v2(&consensus)==ATC_OK);
    CHECK(atc_estimate_rigid_consensus_v2(&consensus,nullptr,0,&extended.value)==ATC_NO_MATCH&&!extended.value.valid);
    for(auto c:extended.tail)CHECK(c==0x5A);
    ATCMapInfoV2 map{}; map.struct_size=sizeof(map); map.api_version=1;
    std::memset(reinterpret_cast<unsigned char*>(&map)+8,0xB4,sizeof(map)-8);
    CHECK(atc_load_map(h,"/private/tmp",&map)==ATC_ABI_MISMATCH);
    for(size_t i=8;i<sizeof(map);++i) CHECK(reinterpret_cast<unsigned char*>(&map)[i]==0xB4);
    ATCResultV2 mismatched{}; mismatched.struct_size=sizeof(mismatched); mismatched.api_version=1;
    mismatched.raw_pose_valid=1;
    CHECK(atc_localize(h,nullptr,&mismatched)==ATC_ABI_MISMATCH && mismatched.raw_pose_valid==1);
    ATCResultV2 out{}; out.struct_size=sizeof(out); out.api_version=2; out.raw_pose_valid=1;
    CHECK(atc_localize(h,nullptr,&out)==ATC_INVALID_ARGUMENT && !out.raw_pose_valid);
    unsigned char pixel=0;
    ATCFrameV2 f{}; f.struct_size=sizeof(f); f.api_version=2; f.data=&pixel; f.byte_length=1;
    f.width=1; f.height=1; f.row_stride=1; f.pixel_format=ATC_PIXEL_FORMAT_GRAY8;
    f.fx=1; f.fy=1; f.frame_id=1; f.capture_timestamp_ns=1; f.map_generation=1;
    CHECK(atc_localize(h,&f,&out)==ATC_MAP_NOT_LOADED && !out.raw_pose_valid);
    auto invalid=f; invalid.byte_length=0;
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.row_stride=0;
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.data=nullptr;
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.struct_size=8;
    CHECK(atc_localize(h,&invalid,&out)==ATC_ABI_MISMATCH);
    invalid=f; invalid.height=2; invalid.row_stride=UINT64_MAX; invalid.byte_length=UINT64_MAX;
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.pixel_format=77;
    CHECK(atc_localize(h,&invalid,&out)==ATC_UNSUPPORTED_FORMAT);
    invalid=f; invalid.fx=std::numeric_limits<float>::infinity();
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.fy=0;
    CHECK(atc_localize(h,&invalid,&out)==ATC_INVALID_ARGUMENT);
    invalid=f; invalid.width=config.max_dimension+1; invalid.row_stride=invalid.width; invalid.byte_length=invalid.width;
    CHECK(atc_localize(h,&invalid,&out)==ATC_RESOURCE_LIMIT);
    CHECK(atc_reset(h)==ATC_OK);
    atc_destroy(&h); CHECK(!h);
    atc_destroy(&h); CHECK(!h);
    atc_destroy(nullptr);
    CHECK(atc_reset(nullptr)==ATC_INVALID_ARGUMENT);
    atc_destroy(&h2); CHECK(!h2);
    std::cout << "legacy ABI 76/48; v2 frame="<<sizeof(ATCFrameV2)<<" result="<<sizeof(ATCResultV2)<<" config="<<sizeof(ATCConfigV2)<<" map="<<sizeof(ATCMapInfoV2)<<" tracking="<<sizeof(ATCTrackingSampleV2)<<" session_config="<<sizeof(ATCSessionConfigV2)<<" session_result="<<sizeof(ATCSessionResultV2)<<"\n";
  } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
