#include "frame_contract.h"
#include <iostream>
#include <limits>
#define CHECK(c) do {if(!(c)){std::cerr<<#c<<'\n';return 1;}}while(0)
int main(){
 const auto config=atc_default_config_v2();
 unsigned char bytes[9]{};
 ATCFrameV2 f{};f.struct_size=sizeof(f);f.api_version=2;f.data=bytes;f.width=3;f.height=2;
 f.row_stride=6;f.byte_length=9;f.pixel_format=ATC_PIXEL_FORMAT_GRAY8;f.fx=1;f.fy=1;f.cx=1;f.cy=1;
 CHECK(atc::validateFrame(&f,config)==ATC_OK);
 auto bad=f;bad.cx=-1;CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 bad=f;bad.cy=2;CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 bad=f;bad.cx=3;CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 bad=f;--bad.byte_length;CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 bad=f;bad.row_stride=UINT64_MAX;bad.byte_length=UINT64_MAX;
 CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 bad=f;bad.fy=std::numeric_limits<float>::quiet_NaN();CHECK(atc::validateFrame(&bad,config)==ATC_INVALID_ARGUMENT);
 auto tight=config;tight.max_image_bytes=8;CHECK(atc::validateFrame(&f,tight)==ATC_RESOURCE_LIMIT);
 tight=config;tight.max_dimension=2;CHECK(atc::validateFrame(&f,tight)==ATC_RESOURCE_LIMIT);
 f.height=1;f.row_stride=UINT64_MAX;f.byte_length=3;f.cy=0;
 CHECK(atc::validateFrame(&f,config)==ATC_OK); // No trailing padding of final row is read.
}
