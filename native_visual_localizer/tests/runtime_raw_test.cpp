#include "area_target_runtime.h"
#include "visual_localizer.h"
#include <opencv2/core.hpp>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <filesystem>
#include <chrono>
#include <sqlite3.h>
#include <iostream>
#include <stdexcept>
#include <vector>
#define CHECK(c) do { if (!(c)) throw std::runtime_error(#c); } while (0)
struct Runtime { ATCHandle h=nullptr; ~Runtime(){atc_destroy(&h);} };
struct Legacy { VLHandle h=vl_create(); ~Legacy(){vl_destroy(h);} };
static ATCResultV2 output() { ATCResultV2 r{}; r.struct_size=sizeof(r); r.api_version=2; return r; }
int main(int argc,char** argv) {
 try {
  CHECK(argc==2); std::string path=argv[1];
  std::ifstream file(path+"/fixture.bin",std::ios::binary); CHECK(file.good());
  int32_t count=0; file.read(reinterpret_cast<char*>(&count),4); CHECK(count==2000);
  std::vector<uint8_t> image(640*480), descriptors(count*32);
  std::vector<float> xyz(count*3),xy(count*2);
  file.read(reinterpret_cast<char*>(image.data()),image.size());
  file.read(reinterpret_cast<char*>(descriptors.data()),descriptors.size());
  file.read(reinterpret_cast<char*>(xyz.data()),xyz.size()*4);
  file.read(reinterpret_cast<char*>(xy.data()),xy.size()*4); CHECK(file.good());
  cv::setNumThreads(1); cv::setRNGSeed(20261004);
  Legacy old; CHECK(old.h);
  for (int i=0;i<count;++i) CHECK(vl_add_vocabulary_word(old.h,i,descriptors.data()+32*i,32,1));
  const float pose[16]={1,0,0,-.15f,0,1,0,.23f,0,0,1,-.34f,0,0,0,1};
  CHECK(vl_add_keyframe(old.h,7,pose,descriptors.data(),count,xyz.data(),xy.data())); CHECK(vl_build_index(old.h));
  VLResult legacy{}; cv::setRNGSeed(20261004);
  vl_process_frame_out(old.h,image.data(),640,480,500,510,320,240,0,nullptr,&legacy); CHECK(legacy.state==1);
  Runtime runtime; const auto cfg=atc_default_config_v2(); CHECK(atc_create(&cfg,&runtime.h)==ATC_OK);
  ATCMapInfoV2 map{}; map.struct_size=sizeof(map); map.api_version=2;
  CHECK(atc_load_map(runtime.h,path.c_str(),&map)==ATC_OK);
  CHECK(map.map_instance_id!=0 && map.orb_feature_count==2000 && map.keyframe_count==1 && map.vocabulary_word_count==2000);
  ATCFrameV2 frame{}; frame.struct_size=sizeof(frame); frame.api_version=2;
  frame.frame_id=42; frame.capture_timestamp_ns=100000000; frame.map_generation=7;
  frame.capture_clock_epoch=11; frame.camera_id=2; frame.data=image.data(); frame.byte_length=image.size();
  frame.width=640; frame.height=480; frame.row_stride=640; frame.pixel_format=ATC_PIXEL_FORMAT_GRAY8;
  frame.fx=500; frame.fy=510; frame.cx=320; frame.cy=240;
  auto result=output(); cv::setRNGSeed(20261004);
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK);
  CHECK(result.raw_pose_valid && result.inliers>=100 && result.confidence>0);
  CHECK(result.reprojection_error_valid && std::isfinite(result.reprojection_rmse_px) && result.reprojection_rmse_px>0 && result.reprojection_rmse_px<2);
  CHECK(result.frame_id==42 && result.capture_timestamp_ns==100000000 && result.map_generation==7);
  CHECK(result.capture_clock_epoch==11 && result.camera_id==2 && result.map_instance_id==map.map_instance_id);
  const float expected[16]={1,0,0,.15f,0,-1,0,.23f,0,0,-1,-.34f,0,0,0,1};
  for(int i=0;i<16;++i) {
   const float sign=(i/4==1 || i/4==2)?-1.f:1.f;
   CHECK(std::fabs(result.camera_from_scan[i]-sign*legacy.pose[i])<.0001f);
   CHECK(std::fabs(result.camera_from_scan[i]-expected[i])<.01f);
  }
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_STALE_FRAME && !result.raw_pose_valid);
  ++frame.frame_id; CHECK(atc_localize(runtime.h,&frame,&result)==ATC_STALE_FRAME);
  ++frame.capture_timestamp_ns; ++frame.camera_id; CHECK(atc_localize(runtime.h,&frame,&result)==ATC_STALE_FRAME);
  --frame.camera_id; CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK);
  ++frame.frame_id; ++frame.capture_timestamp_ns; ++frame.capture_clock_epoch;
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_STALE_FRAME); --frame.capture_clock_epoch;
  ++frame.map_generation; CHECK(atc_localize(runtime.h,&frame,&result)==ATC_STALE_FRAME); --frame.map_generation;
  CHECK(atc_reset(runtime.h)==ATC_OK);
  std::vector<uint8_t> padded((480-1)*672+640,0xFA);
  for (int y=0;y<480;++y) std::copy_n(image.data()+y*640,640,padded.data()+y*672);
  frame.row_stride=672; frame.data=padded.data(); frame.byte_length=padded.size();
  cv::setRNGSeed(20261004); CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK);
  for(int i=0;i<16;++i) CHECK(std::fabs(result.camera_from_scan[i]-expected[i])<.01f);
  ++frame.frame_id; ++frame.capture_timestamp_ns; --frame.byte_length;
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_INVALID_ARGUMENT && !result.raw_pose_valid && !result.reprojection_error_valid);
  std::vector<uint8_t> blank(640*480,0); frame.data=blank.data(); frame.row_stride=640; frame.byte_length=blank.size();
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_NO_MATCH);
  CHECK(!result.raw_pose_valid && !result.reprojection_error_valid && !result.inliers && result.confidence==0);
  ++frame.frame_id; ++frame.capture_timestamp_ns; frame.data=image.data();
  const uint64_t instance=map.map_instance_id;
  CHECK(atc_load_map(runtime.h,"/private/tmp/nonexistent-area-target-bundle",&map)==ATC_MAP_INVALID);
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK && result.map_instance_id==instance);
  map.struct_size=sizeof(map); map.api_version=2;
  CHECK(atc_load_map(runtime.h,path.c_str(),&map)==ATC_OK && map.map_instance_id!=instance);
  // Successful map loading clears frame binding; earlier sequence can bind anew.
  frame.frame_id=0; frame.capture_timestamp_ns=0; frame.map_generation=0; frame.capture_clock_epoch=0; frame.camera_id=0;
  CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK && result.map_instance_id==map.map_instance_id);
  const float baselineRmse=result.reprojection_rmse_px;
  const auto temp=std::filesystem::temp_directory_path()/
      ("atc-runtime-raw-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  struct Cleanup {std::filesystem::path p; ~Cleanup(){std::error_code e;std::filesystem::remove_all(p,e);}} cleanup{temp};
  std::filesystem::create_directories(temp);
  std::filesystem::copy_file(path+"/features.db",temp/"features.db");
  sqlite3* db=nullptr; CHECK(sqlite3_open((temp/"features.db").string().c_str(),&db)==SQLITE_OK);
  struct Database {sqlite3* db; ~Database(){if(db)sqlite3_close(db);}} database{db};
  // A second, worse candidate must not overwrite the winner's residual.
  CHECK(sqlite3_exec(db,"INSERT INTO keyframes SELECT 8,pose,global_descriptor FROM keyframes WHERE id=7;"
      "INSERT INTO features SELECT id+2000,8,x,y,x3d+CASE WHEN id%3=0 THEN .5 ELSE .002*(id%5) END,y3d,z3d,descriptor FROM features WHERE keyframe_id=7;",
      nullptr,nullptr,nullptr)==SQLITE_OK);
  CHECK(atc_load_map(runtime.h,temp.string().c_str(),&map)==ATC_OK);
  cv::setRNGSeed(20261004); CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK);
  CHECK(result.inliers==static_cast<uint32_t>(legacy.matched_features));
  CHECK(std::fabs(result.reprojection_rmse_px-baselineRmse)<.00001f);
  for(int i=0;i<16;++i) CHECK(std::fabs(result.camera_from_scan[i]-expected[i])<.01f);
  CHECK(sqlite3_exec(db,"DELETE FROM features WHERE keyframe_id=8; DELETE FROM keyframes WHERE id=8;"
      "UPDATE features SET x3d=1-y3d,y3d=x3d-2,z3d=z3d+.5;",nullptr,nullptr,nullptr)==SQLITE_OK);
  // S2_from_S rotates 90 degrees around z and translates (1,-2,.5).
  const double rotatedScanFromCamera[16]={0,-1,0,.77,1,0,0,-2.15,0,0,1,.16,0,0,0,1};
  sqlite3_stmt* stmt=nullptr;
  CHECK(sqlite3_prepare_v2(db,"UPDATE keyframes SET pose=? WHERE id=7",-1,&stmt,nullptr)==SQLITE_OK);
  CHECK(sqlite3_bind_blob(stmt,1,rotatedScanFromCamera,sizeof(rotatedScanFromCamera),SQLITE_TRANSIENT)==SQLITE_OK);
  CHECK(sqlite3_step(stmt)==SQLITE_DONE); sqlite3_finalize(stmt);
  CHECK(atc_load_map(runtime.h,temp.string().c_str(),&map)==ATC_OK);
  cv::setRNGSeed(20261004); CHECK(atc_localize(runtime.h,&frame,&result)==ATC_OK);
  const float rotatedExpected[16]={0,1,0,2.15f,1,0,0,-.77f,0,0,-1,.16f,0,0,0,1};
  for(int i=0;i<16;++i) CHECK(std::fabs(result.camera_from_scan[i]-rotatedExpected[i])<.01f);
  std::cout<<"real Raw: optical pose agrees with legacy basis conversion, "<<result.inliers<<" inliers, RMSE "<<result.reprojection_rmse_px<<" px\n";
 } catch(const std::exception& e) {std::cerr<<e.what()<<'\n'; return 1;}
}
