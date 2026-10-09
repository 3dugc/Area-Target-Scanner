#include "map_loader.h"
#include <sqlite3.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace atc {
namespace {
struct LoadFailure { ATCStatus status; };
[[noreturn]] void fail(ATCStatus status=ATC_MAP_INVALID) { throw LoadFailure{status}; }
void require(bool condition,ATCStatus status=ATC_MAP_INVALID) { if(!condition)fail(status); }
struct DatabaseCloser { void operator()(sqlite3* db) const { if(db)sqlite3_close_v2(db); } };
struct StatementCloser { void operator()(sqlite3_stmt* s) const { if(s)sqlite3_finalize(s); } };
using Database=std::unique_ptr<sqlite3,DatabaseCloser>;
using Statement=std::unique_ptr<sqlite3_stmt,StatementCloser>;

// Progress interrupts long individual statements. The per-step VM counter also
// charges short statements, so many small SELECTs cannot evade the same budget.
struct SQLBudget {
 using Clock=std::chrono::steady_clock;
 uint64_t maximum_steps,maximum_time_ns,executed_steps=0,progress_steps=0;
 int interval;
 Clock::time_point started=Clock::now();
 bool exhausted=false;
 SQLBudget(uint64_t steps,uint64_t time):maximum_steps(steps),maximum_time_ns(time),
  interval(static_cast<int>(std::min<uint64_t>(1000,steps))) {}
 bool timedOut() const { return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-started).count())>=maximum_time_ns; }
 void check() { if(exhausted||timedOut()) { exhausted=true;fail(ATC_RESOURCE_LIMIT); } }
 void charge(sqlite3_stmt* s) {
  const uint64_t steps=static_cast<uint64_t>(sqlite3_stmt_status(s,SQLITE_STMTSTATUS_VM_STEP,1));
  if(steps>maximum_steps-executed_steps){exhausted=true;fail(ATC_RESOURCE_LIMIT);}
  executed_steps+=steps;check();
 }
 static int progress(void* raw) {
  auto& b=*static_cast<SQLBudget*>(raw);
  if(b.progress_steps>b.maximum_steps-static_cast<uint64_t>(b.interval)||b.timedOut()) {b.exhausted=true;return 1;}
  b.progress_steps+=static_cast<uint64_t>(b.interval);return 0;
 }
};
struct SQLScope {
 sqlite3* db;SQLBudget& budget;bool transaction=false;
 SQLScope(sqlite3* connection,SQLBudget& b):db(connection),budget(b){sqlite3_progress_handler(db,b.interval,SQLBudget::progress,&b);}
 ~SQLScope(){
  // Cleanup must not itself be interrupted or throw. No writes were permitted.
  sqlite3_progress_handler(db,0,nullptr,nullptr);
  if(transaction)sqlite3_exec(db,"ROLLBACK",nullptr,nullptr,nullptr);
 }
};
void sqlError(int rc,const SQLBudget& budget) {
 if(budget.exhausted||rc==SQLITE_INTERRUPT)fail(ATC_RESOURCE_LIMIT);
 if(rc==SQLITE_TOOBIG)fail(ATC_RESOURCE_LIMIT);
 if(rc==SQLITE_NOMEM)fail(ATC_INTERNAL_ERROR);
 fail();
}
class Rows {
 sqlite3* db_;SQLBudget& budget_;Statement statement_;
public:
 Rows(sqlite3* db,SQLBudget& b,const std::string& sql):db_(db),budget_(b) {
  budget_.check();sqlite3_stmt* raw=nullptr;
  const int rc=sqlite3_prepare_v2(db,sql.c_str(),-1,&raw,nullptr);statement_.reset(raw);
  if(rc!=SQLITE_OK||!raw)sqlError(rc,budget_);budget_.check();
 }
 void bind(uint64_t value){require(value<=static_cast<uint64_t>(std::numeric_limits<int64_t>::max()));if(sqlite3_bind_int64(statement_.get(),1,static_cast<int64_t>(value))!=SQLITE_OK)fail();}
 bool next(){budget_.check();const int rc=sqlite3_step(statement_.get());budget_.charge(statement_.get());if(rc!=SQLITE_ROW&&rc!=SQLITE_DONE)sqlError(rc,budget_);return rc==SQLITE_ROW;}
 int type(int c)const{return sqlite3_column_type(statement_.get(),c);}
 std::string text(int c)const{require(type(c)==SQLITE_TEXT);const auto* p=sqlite3_column_text(statement_.get(),c);require(p);return std::string(reinterpret_cast<const char*>(p),static_cast<size_t>(sqlite3_column_bytes(statement_.get(),c)));}
 int32_t id(int c)const{require(type(c)==SQLITE_INTEGER);const int64_t n=sqlite3_column_int64(statement_.get(),c);require(n>=0&&n<=INT32_MAX);return static_cast<int32_t>(n);}
 uint64_t count(int c)const{require(type(c)==SQLITE_INTEGER);const int64_t n=sqlite3_column_int64(statement_.get(),c);require(n>=0);return static_cast<uint64_t>(n);}
 float number(int c)const{require(type(c)==SQLITE_INTEGER||type(c)==SQLITE_FLOAT);const double value=sqlite3_column_double(statement_.get(),c);const float narrow=static_cast<float>(value);require(std::isfinite(value)&&std::isfinite(narrow));return narrow;}
 const unsigned char* blob(int c,int bytes)const{require(type(c)==SQLITE_BLOB&&sqlite3_column_bytes(statement_.get(),c)==bytes);const auto* p=static_cast<const unsigned char*>(sqlite3_column_blob(statement_.get(),c));require(p);return p;}
};
void execute(sqlite3* db,SQLBudget& budget,const char* sql){Rows rows(db,budget,sql);require(!rows.next());}
using Columns=std::vector<std::pair<const char*,const char*>>;
const Columns featureColumns={{"id","INTEGER"},{"keyframe_id","INTEGER"},{"x","REAL"},{"y","REAL"},{"x3d","REAL"},{"y3d","REAL"},{"z3d","REAL"},{"descriptor","BLOB"}};
bool tableExists(sqlite3* db,SQLBudget& budget,const std::string& table){Rows rows(db,budget,"SELECT type FROM sqlite_master WHERE name='"+table+"'");const bool exists=rows.next();if(exists)require(!rows.next());return exists;}
void requireTable(sqlite3* db,SQLBudget& budget,const std::string& table,const Columns& columns){
 Rows schema(db,budget,"SELECT type,sql FROM sqlite_master WHERE name='"+table+"'");
 require(schema.next());require(schema.text(0)=="table");std::string sql=schema.text(1);
 std::transform(sql.begin(),sql.end(),sql.begin(),[](unsigned char c){return static_cast<char>(std::toupper(c));});
 // Virtual tables are represented as type=table too. They must never execute
 // extension/module code during map loading.
 require(sql.rfind("CREATE TABLE",0)==0);require(!schema.next());
 Rows info(db,budget,"PRAGMA table_info("+table+")");std::unordered_map<std::string,std::string> actual;
 while(info.next()){
  std::string name=info.text(1),type=info.text(2);
  std::transform(type.begin(),type.end(),type.begin(),[](unsigned char c){return static_cast<char>(std::toupper(c));});
  require(actual.emplace(std::move(name),std::move(type)).second);
 }
 for(const auto& column:columns){const auto found=actual.find(column.first);require(found!=actual.end()&&found->second==column.second);}
}
uint64_t boundedCount(sqlite3* db,SQLBudget& budget,const std::string& table,uint64_t maximum){
 Rows rows(db,budget,"SELECT COUNT(*) FROM (SELECT 1 FROM "+table+" LIMIT ?)");rows.bind(maximum+1);
 require(rows.next());const auto count=rows.count(0);require(count<=maximum,ATC_RESOURCE_LIMIT);require(!rows.next());return count;
}
void perKeyframeLimit(sqlite3* db,SQLBudget& budget,const std::string& table,uint64_t maximum){
 Rows rows(db,budget,"SELECT keyframe_id FROM "+table+" GROUP BY keyframe_id HAVING COUNT(*)>? LIMIT 1");rows.bind(maximum);require(!rows.next(),ATC_RESOURCE_LIMIT);
}
std::array<float,16> decodePose(const unsigned char* bytes){
 std::array<float,16> pose{};
 for(size_t i=0;i<pose.size();++i){
  uint64_t bits=0;for(size_t j=0;j<8;++j)bits|=static_cast<uint64_t>(bytes[i*8+j])<<(j*8);
  double value;std::memcpy(&value,&bits,sizeof(value));pose[i]=static_cast<float>(value);
  require(std::isfinite(value)&&std::isfinite(pose[i]));
 }
 constexpr double affineTolerance=.0001,rotationTolerance=.001;
 require(std::fabs(pose[12])<affineTolerance&&std::fabs(pose[13])<affineTolerance&&std::fabs(pose[14])<affineTolerance&&std::fabs(pose[15]-1)<affineTolerance);
 for(int column=0;column<3;++column)for(int other=0;other<3;++other){
  double dot=0;for(int row=0;row<3;++row)dot+=static_cast<double>(pose[row*4+column])*pose[row*4+other];
  require(std::fabs(dot-(column==other?1.0:0.0))<=rotationTolerance);
 }
 const double determinant=pose[0]*(static_cast<double>(pose[5])*pose[10]-static_cast<double>(pose[6])*pose[9])-pose[1]*(static_cast<double>(pose[4])*pose[10]-static_cast<double>(pose[6])*pose[8])+pose[2]*(static_cast<double>(pose[4])*pose[9]-static_cast<double>(pose[5])*pose[8]);
 require(std::fabs(determinant-1)<=rotationTolerance);return pose;
}
struct FeatureBlock {
 std::vector<unsigned char> descriptors;std::vector<float> points2d,points3d;
 size_t count()const{return points2d.size()/2;}
 void reserve(uint64_t n,int length){descriptors.reserve(static_cast<size_t>(n)*length);points2d.reserve(static_cast<size_t>(n)*2);points3d.reserve(static_cast<size_t>(n)*3);}
};
struct Keyframe {int32_t id;std::array<float,16> pose;FeatureBlock orb,akaze;};
void readFeatures(sqlite3* db,SQLBudget& budget,const std::string& table,int descriptorLength,
 const std::unordered_map<int32_t,size_t>& positions,std::vector<Keyframe>& frames,uint64_t expected,uint64_t perFrame){
 Rows rows(db,budget,"SELECT id,keyframe_id,x,y,x3d,y3d,z3d,descriptor FROM "+table+" ORDER BY keyframe_id,id");
 std::unordered_set<int32_t> seen;seen.reserve(static_cast<size_t>(expected));uint64_t loaded=0;
 while(rows.next()){
  require(++loaded<=expected,ATC_RESOURCE_LIMIT);require(seen.insert(rows.id(0)).second);
  auto position=positions.find(rows.id(1));require(position!=positions.end());
  auto& block=descriptorLength==32?frames[position->second].orb:frames[position->second].akaze;
  require(block.count()<perFrame,ATC_RESOURCE_LIMIT);
  const auto* descriptor=rows.blob(7,descriptorLength);
  const float x=rows.number(2),y=rows.number(3),px=rows.number(4),py=rows.number(5),pz=rows.number(6);
  block.descriptors.insert(block.descriptors.end(),descriptor,descriptor+descriptorLength);
  block.points2d.insert(block.points2d.end(),{x,y});block.points3d.insert(block.points3d.end(),{px,py,pz});
 }
 require(loaded==expected);
}
} // namespace

MapCandidate loadMap(const char* bundle_directory,const ATCConfigV2& config){
 MapCandidate result;
 try {
  std::vector<VocabWord> vocabulary;
  std::vector<Keyframe> frames;
  uint64_t frameCount=0,wordCount=0,orbCount=0,akazeCount=0;
  {
  require(bundle_directory&&*bundle_directory);
  const std::string path=std::string(bundle_directory)+"/features.db";
  struct stat before{};require(lstat(path.c_str(),&before)==0&&S_ISREG(before.st_mode)&&before.st_size>0);
  require(static_cast<uint64_t>(before.st_size)<=config.max_database_bytes,ATC_RESOURCE_LIMIT);
  sqlite3* raw=nullptr;const int rc=sqlite3_open_v2(path.c_str(),&raw,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nullptr);
  Database database(raw);require(rc==SQLITE_OK&&raw);
  struct stat after{};require(lstat(path.c_str(),&after)==0&&S_ISREG(after.st_mode)&&after.st_dev==before.st_dev&&after.st_ino==before.st_ino&&after.st_size==before.st_size);
  sqlite3_busy_timeout(raw,250);
  sqlite3_limit(raw,SQLITE_LIMIT_LENGTH,128*1024);sqlite3_limit(raw,SQLITE_LIMIT_SQL_LENGTH,4096);sqlite3_limit(raw,SQLITE_LIMIT_COLUMN,64);
  SQLBudget budget(config.max_sql_steps,config.max_sql_time_ns);SQLScope scope(raw,budget);
  execute(raw,budget,"PRAGMA query_only=ON");execute(raw,budget,"PRAGMA trusted_schema=OFF");execute(raw,budget,"BEGIN");scope.transaction=true;
  {Rows check(raw,budget,"PRAGMA quick_check(1)");require(check.next()&&check.text(0)=="ok");require(!check.next());}
  requireTable(raw,budget,"keyframes",{{"id","INTEGER"},{"pose","BLOB"},{"global_descriptor","BLOB"}});
  requireTable(raw,budget,"features",featureColumns);
  requireTable(raw,budget,"vocabulary",{{"word_id","INTEGER"},{"descriptor","BLOB"},{"idf_weight","REAL"}});
  const bool hasAkaze=tableExists(raw,budget,"akaze_features");if(hasAkaze)requireTable(raw,budget,"akaze_features",featureColumns);
  frameCount=boundedCount(raw,budget,"keyframes",config.max_keyframes);
  wordCount=boundedCount(raw,budget,"vocabulary",config.max_vocabulary_words);
  orbCount=boundedCount(raw,budget,"features",config.max_total_features);
  akazeCount=hasAkaze?boundedCount(raw,budget,"akaze_features",config.max_total_features):0;
  require(frameCount>0&&wordCount>0&&orbCount>0);
  require(orbCount<=config.max_total_features-akazeCount,ATC_RESOURCE_LIMIT);
  require(orbCount<=config.max_bow_products/wordCount,ATC_RESOURCE_LIMIT);
  perKeyframeLimit(raw,budget,"features",config.max_orb_features_per_keyframe);
  if(hasAkaze)perKeyframeLimit(raw,budget,"akaze_features",config.max_akaze_features_per_keyframe);

  vocabulary.reserve(static_cast<size_t>(wordCount));
  {
   Rows words(raw,budget,"SELECT word_id,descriptor,idf_weight FROM vocabulary ORDER BY word_id");
   std::unordered_set<int32_t> seen;seen.reserve(static_cast<size_t>(wordCount));uint64_t loaded=0;
   while(words.next()) {require(++loaded<=wordCount,ATC_RESOURCE_LIMIT);const int32_t id=words.id(0);require(seen.insert(id).second);const auto* descriptor=words.blob(1,32);vocabulary.push_back(VocabWord{id,std::vector<unsigned char>(descriptor,descriptor+32),words.number(2)});}
   require(loaded==wordCount);
  }
  frames.reserve(static_cast<size_t>(frameCount));
  std::unordered_map<int32_t,size_t> positions;positions.reserve(static_cast<size_t>(frameCount));
  {
   Rows rows(raw,budget,"SELECT id,pose FROM keyframes ORDER BY id");
   while(rows.next()){
    require(frames.size()<frameCount,ATC_RESOURCE_LIMIT);const int32_t id=rows.id(0);require(positions.emplace(id,frames.size()).second);
    frames.push_back(Keyframe{id,decodePose(rows.blob(1,128)),{}, {}});
   }
   require(frames.size()==frameCount);
  }
  readFeatures(raw,budget,"features",32,positions,frames,orbCount,config.max_orb_features_per_keyframe);
  for(const auto& frame:frames)require(frame.orb.count()>0);
  if(hasAkaze)readFeatures(raw,budget,"akaze_features",61,positions,frames,akazeCount,config.max_akaze_features_per_keyframe);
  budget.check();
  } // The complete validated snapshot now owns its bytes; close SQL resources.

  // Native BoW work has its own frozen product bound, separate from the SQL
  // VM/time budget. A large valid map must not consume its SQL deadline here.
  auto localizer=std::make_unique<VisualLocalizer>();
  for(const auto& word:vocabulary)localizer->addVocabularyWord(word.word_id,word.descriptor.data(),32,word.idf_weight);
  for(auto& frame:frames){
   localizer->addKeyframe(frame.id,frame.pose.data(),frame.orb.descriptors.data(),static_cast<int>(frame.orb.count()),frame.orb.points3d.data(),frame.orb.points2d.data());
   frame.orb=FeatureBlock{};
  }
  for(auto& frame:frames)if(frame.akaze.count()>0){
   localizer->addKeyframeAkaze(frame.id,frame.akaze.descriptors.data(),static_cast<int>(frame.akaze.count()),61,frame.akaze.points3d.data(),frame.akaze.points2d.data());
   frame.akaze=FeatureBlock{};
  }
  require(localizer->buildIndex(),ATC_INTERNAL_ERROR);
  result.info.struct_size=sizeof(result.info);result.info.api_version=ATC_API_VERSION;
  result.info.keyframe_count=frameCount;result.info.orb_feature_count=orbCount;result.info.akaze_feature_count=akazeCount;result.info.vocabulary_word_count=wordCount;
  result.info.asset_schema_compatibility_id=ATC_ASSET_SCHEMA_LEGACY_V1;result.info.map_coordinate_policy=config.map_coordinate_policy;
  result.localizer=std::move(localizer);result.status=ATC_OK;
 } catch(const LoadFailure& failure){result.status=failure.status;}
 return result;
}
} // namespace atc
