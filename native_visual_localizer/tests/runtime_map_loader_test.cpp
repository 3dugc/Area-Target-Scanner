#include "area_target_runtime.h"
#include <sqlite3.h>
#include <opencv2/core.hpp>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>
namespace fs=std::filesystem;
#define CHECK(c) do { if(!(c)) throw std::runtime_error(#c); } while(0)
struct Runtime {
 ATCHandle handle=nullptr;
 explicit Runtime(const ATCConfigV2& c=atc_default_config_v2()){CHECK(atc_create(&c,&handle)==ATC_OK);}
 ~Runtime(){atc_destroy(&handle);}
 ATCStatus load(const std::string& path,ATCMapInfoV2* result=nullptr){
  ATCMapInfoV2 info{}; info.struct_size=sizeof(info);info.api_version=2;
  auto status=atc_load_map(handle,path.c_str(),&info);if(result)*result=info;return status;
 }
};
static void sql(sqlite3* db,const std::string& text){
 char* error=nullptr;const int rc=sqlite3_exec(db,text.c_str(),nullptr,nullptr,&error);
 std::string message=error?error:"SQLite failure";sqlite3_free(error);
 if(rc!=SQLITE_OK)throw std::runtime_error(message);
}
static std::vector<unsigned char> poseBlob(std::array<double,16> pose={1,0,0,.25,0,1,0,-.5,0,0,1,1.25,0,0,0,1},bool bigEndian=false){
 std::vector<unsigned char> bytes(128);
 for(size_t i=0;i<pose.size();++i){uint64_t bits;std::memcpy(&bits,&pose[i],8);for(size_t j=0;j<8;++j)bytes[i*8+j]=static_cast<unsigned char>(bits>>((bigEndian?7-j:j)*8));}
 return bytes;
}
struct Database {
 fs::path directory; sqlite3* db=nullptr;
 explicit Database(bool akaze=false){
  char pattern[]="/private/tmp/atc-map-test-XXXXXX";const char* result=mkdtemp(pattern);CHECK(result);directory=result;
  CHECK(sqlite3_open((directory/"features.db").c_str(),&db)==SQLITE_OK);
  // Deliberately no primary keys: the reader must detect duplicates itself.
  sql(db,"CREATE TABLE keyframes(id INTEGER,pose BLOB,global_descriptor BLOB);"
   "CREATE TABLE features(id INTEGER,keyframe_id INTEGER,x REAL,y REAL,x3d REAL,y3d REAL,z3d REAL,descriptor BLOB);"
   "CREATE TABLE vocabulary(word_id INTEGER,descriptor BLOB,idf_weight REAL);");
  setPose(poseBlob());
  sql(db,"INSERT INTO vocabulary VALUES(0,zeroblob(32),1);"
   "INSERT INTO features VALUES(0,7,10,20,1,2,3,zeroblob(32));");
  if(akaze){sql(db,"CREATE TABLE akaze_features(id INTEGER,keyframe_id INTEGER,x REAL,y REAL,x3d REAL,y3d REAL,z3d REAL,descriptor BLOB);"
   "INSERT INTO akaze_features VALUES(0,7,10,20,1,2,3,zeroblob(61));");}
 }
 void setPose(const std::vector<unsigned char>& bytes){
  sql(db,"DELETE FROM keyframes");sqlite3_stmt* s=nullptr;
  CHECK(sqlite3_prepare_v2(db,"INSERT INTO keyframes VALUES(7,?,NULL)",-1,&s,nullptr)==SQLITE_OK);
  CHECK(sqlite3_bind_blob(s,1,bytes.data(),static_cast<int>(bytes.size()),SQLITE_TRANSIENT)==SQLITE_OK);
  const int rc=sqlite3_step(s);sqlite3_finalize(s);CHECK(rc==SQLITE_DONE);
 }
 void close(){if(db){CHECK(sqlite3_close(db)==SQLITE_OK);db=nullptr;}}
 ~Database(){if(db)sqlite3_close(db);std::error_code ignored;fs::remove_all(directory,ignored);}
};
static int cases=0;
static void test(const std::string& name,const std::function<void()>& run){
 try{run();++cases;}catch(const std::exception& e){throw std::runtime_error(name+": "+e.what());}
}
static void rejects(const std::string& name,const std::string& mutation,bool akaze=false,ATCStatus expected=ATC_MAP_INVALID){
 test(name,[&]{Database db(akaze);sql(db.db,mutation);db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==expected);});
}
static void limited(const std::string& name,const std::function<void(ATCConfigV2&)>& change,const std::string& mutation="",bool akaze=false){
 test(name,[&]{Database db(akaze);if(!mutation.empty())sql(db.db,mutation);db.close();auto config=atc_default_config_v2();change(config);Runtime runtime(config);CHECK(runtime.load(db.directory.string())==ATC_RESOURCE_LIMIT);});
}
int main(int argc,char** argv){try{
 CHECK(argc==2);cv::setNumThreads(1);
 test("valid ordinary tables without PK or mesh",[]{Database db;db.close();Runtime runtime;ATCMapInfoV2 info{};CHECK(runtime.load(db.directory.string(),&info)==ATC_OK);CHECK(info.keyframe_count==1&&info.orb_feature_count==1&&info.akaze_feature_count==0&&info.vocabulary_word_count==1);CHECK(info.asset_schema_compatibility_id==ATC_ASSET_SCHEMA_LEGACY_V1&&info.map_coordinate_policy==ATC_MAP_COORDINATE_LEGACY_SCAN_RH_METERS&&info.map_instance_id!=0);});
 test("optional AKAZE61",[]{Database db(true);db.close();Runtime runtime;ATCMapInfoV2 info{};CHECK(runtime.load(db.directory.string(),&info)==ATC_OK&&info.akaze_feature_count==1);});
 rejects("missing required table","DROP TABLE vocabulary");
 rejects("view masquerading as features","ALTER TABLE features RENAME TO actual_features;CREATE VIEW features AS SELECT * FROM actual_features");
 rejects("optional AKAZE view","CREATE VIEW akaze_features AS SELECT * FROM features");
 rejects("wrong declared schema type","ALTER TABLE vocabulary RENAME TO old_words;CREATE TABLE vocabulary(word_id INTEGER,descriptor TEXT,idf_weight REAL);INSERT INTO vocabulary SELECT * FROM old_words");
 rejects("empty keyframes","DELETE FROM keyframes");
 rejects("empty ORB","DELETE FROM features");
 rejects("empty vocabulary","DELETE FROM vocabulary");
 rejects("keyframe without ORB","INSERT INTO keyframes SELECT 8,pose,global_descriptor FROM keyframes");
 rejects("duplicate keyframe ID","INSERT INTO keyframes SELECT * FROM keyframes");
 rejects("duplicate ORB ID","INSERT INTO features SELECT * FROM features");
 rejects("duplicate AKAZE ID","INSERT INTO akaze_features SELECT * FROM akaze_features",true);
 rejects("duplicate word ID","INSERT INTO vocabulary SELECT * FROM vocabulary");
 rejects("orphan ORB","UPDATE features SET keyframe_id=99");
 rejects("orphan AKAZE","UPDATE akaze_features SET keyframe_id=99",true);
 rejects("negative keyframe ID","UPDATE keyframes SET id=-1");
 rejects("out of range feature ID","UPDATE features SET id=2147483648");
 rejects("negative vocabulary ID","UPDATE vocabulary SET word_id=-1");
 rejects("negative referenced keyframe ID","UPDATE features SET keyframe_id=-1");
 rejects("fractional feature ID","UPDATE features SET id=0.5");
 rejects("invalid ORB32","UPDATE features SET descriptor=zeroblob(31)");
 rejects("invalid AKAZE61","UPDATE akaze_features SET descriptor=zeroblob(60)",true);
 rejects("invalid vocabulary32","UPDATE vocabulary SET descriptor=zeroblob(33)");
 rejects("non BLOB descriptor","UPDATE features SET descriptor='01234567890123456789012345678901'");
 rejects("invalid pose128","UPDATE keyframes SET pose=zeroblob(127)");
 rejects("numeric text","UPDATE features SET x='abc'");
 rejects("NULL coordinate","UPDATE features SET y=NULL");
 rejects("infinite coordinate","UPDATE features SET z3d=1e999");
 rejects("float narrowing overflow","UPDATE features SET x3d=1e100");
 rejects("infinite IDF","UPDATE vocabulary SET idf_weight=1e999");
 rejects("IDF float narrowing overflow","UPDATE vocabulary SET idf_weight=1e100");
 test("nonfinite pose",[]{Database db;auto p=std::array<double,16>{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};p[3]=INFINITY;db.setPose(poseBlob(p));db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 test("pose float narrowing overflow",[]{Database db;auto p=std::array<double,16>{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};p[3]=1e100;db.setPose(poseBlob(p));db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 for(const auto& variant:std::vector<std::pair<std::string,std::array<double,16>>>{
  {"scaled pose",{2,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}},
  {"left handed pose",{-1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}},
  {"nonhomogeneous pose",{1,0,0,0,0,1,0,0,0,0,1,0,.01,0,0,1}}})
  test(variant.first,[&]{Database db;db.setPose(poseBlob(variant.second));db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 test("big endian pose is never guessed",[]{Database db;db.setPose(poseBlob({1,0,0,.25,0,1,0,-.5,0,0,1,1.25,0,0,0,1},true));db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 const std::string secondOrb="INSERT INTO features SELECT 1,keyframe_id,x,y,x3d,y3d,z3d,descriptor FROM features";
 limited("configured ORB per keyframe",[](auto& c){c.max_orb_features_per_keyframe=1;},secondOrb);
 limited("configured AKAZE per keyframe",[](auto& c){c.max_akaze_features_per_keyframe=1;},"INSERT INTO akaze_features SELECT 1,keyframe_id,x,y,x3d,y3d,z3d,descriptor FROM akaze_features",true);
 limited("configured total count including AKAZE",[](auto& c){c.max_total_features=1;},"",true);
 limited("configured vocabulary count",[](auto& c){c.max_vocabulary_words=1;},"INSERT INTO vocabulary VALUES(1,zeroblob(32),1)");
 limited("configured keyframe count",[](auto& c){c.max_keyframes=1;},"INSERT INTO keyframes SELECT 8,pose,NULL FROM keyframes;INSERT INTO features SELECT 1,8,x,y,x3d,y3d,z3d,descriptor FROM features");
 limited("configured BoW work",[](auto& c){c.max_bow_products=1;},secondOrb);
 limited("configured file bytes",[](auto& c){c.max_database_bytes=1;});
 limited("configured SQL steps",[](auto& c){c.max_sql_steps=1;});
 limited("configured SQL elapsed time",[](auto& c){c.max_sql_time_ns=1;});
 rejects("frozen ORB2000 cap without primary key","WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<2000) INSERT INTO features SELECT x,7,10,20,1,2,3,zeroblob(32) FROM n",false,ATC_RESOURCE_LIMIT);
 rejects("frozen AKAZE8192 cap","WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<8192) INSERT INTO akaze_features SELECT x,7,10,20,1,2,3,zeroblob(61) FROM n",true,ATC_RESOURCE_LIMIT);
 rejects("frozen vocabulary4096 cap","WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<4096) INSERT INTO vocabulary SELECT x,zeroblob(32),1 FROM n",false,ATC_RESOURCE_LIMIT);
 test("regular nonempty bounded file",[]{Database db;db.close();Runtime runtime;const auto file=db.directory/"features.db";fs::remove(file);std::ofstream(file).close();CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);fs::resize_file(file,UINT64_C(512)*1024*1024+1);CHECK(runtime.load(db.directory.string())==ATC_RESOURCE_LIMIT);fs::remove(file);fs::create_directory(file);CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 test("database symlink rejected",[]{Database db;db.close();fs::rename(db.directory/"features.db",db.directory/"actual.db");fs::create_symlink("actual.db",db.directory/"features.db");Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 test("corrupt SQLite file",[]{Database db;db.close();std::ofstream file(db.directory/"features.db",std::ios::binary|std::ios::trunc);file<<"invalid database";file.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_MAP_INVALID);});
 test("valid empty optional AKAZE table",[]{Database db(true);sql(db.db,"DELETE FROM akaze_features");db.close();Runtime runtime;CHECK(runtime.load(db.directory.string())==ATC_OK);});
 test("existing 92 keyframe production database",[]{
  const fs::path directory=fs::path(__FILE__).parent_path().parent_path().parent_path()/"unity_project/Assets/StreamingAssets/SLAMTestAssets";
  CHECK(fs::is_regular_file(directory/"features.db"));Runtime runtime;ATCMapInfoV2 info{};
  CHECK(runtime.load(directory.string(),&info)==ATC_OK);
  CHECK(info.keyframe_count==92&&info.orb_feature_count==127685&&info.vocabulary_word_count==1000&&info.akaze_feature_count==0);
 });
 test("production fixture BoW order and failed load retains map",[&]{
  const fs::path directory=argv[1];CHECK(fs::exists(directory/"features.db"));
  std::ifstream file(directory/"query.gray8",std::ios::binary);std::vector<unsigned char> image(640*480);file.read(reinterpret_cast<char*>(image.data()),image.size());CHECK(file.good());
  Runtime runtime;ATCMapInfoV2 info{};CHECK(runtime.load(directory.string(),&info)==ATC_OK);CHECK(info.orb_feature_count==2000&&info.vocabulary_word_count==2000);
  ATCFrameV2 frame{};frame.struct_size=sizeof(frame);frame.api_version=2;frame.frame_id=1;frame.capture_timestamp_ns=1;frame.map_generation=1;frame.capture_clock_epoch=1;frame.camera_id=1;frame.data=image.data();frame.byte_length=image.size();frame.row_stride=640;frame.width=640;frame.height=480;frame.pixel_format=ATC_PIXEL_FORMAT_GRAY8;frame.fx=500;frame.fy=510;frame.cx=320;frame.cy=240;
  ATCResultV2 output{};output.struct_size=sizeof(output);output.api_version=2;
  cv::setRNGSeed(20261004);CHECK(atc_localize(runtime.handle,&frame,&output)==ATC_OK&&output.raw_pose_valid&&output.inliers>=100);CHECK(output.map_instance_id==info.map_instance_id);
  Database broken;sql(broken.db,"UPDATE features SET keyframe_id=999");broken.close();CHECK(runtime.load(broken.directory.string())==ATC_MAP_INVALID);
  ++frame.frame_id;++frame.capture_timestamp_ns;CHECK(atc_localize(runtime.handle,&frame,&output)==ATC_OK&&output.map_instance_id==info.map_instance_id);
 });
 std::cout<<"SQLite loader: "<<cases<<" real database cases passed\n";
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
