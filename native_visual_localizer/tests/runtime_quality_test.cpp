#include "area_target_runtime.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <vector>
#define CHECK(c) do { if (!(c)) throw std::runtime_error(#c); } while (0)
using Assess = decltype(&atc_assess_gray_quality);
static Assess assess() {
    CHECK(atc_get_api_version() == 2);
    return &atc_assess_gray_quality;
}
static ATCFrameV2 frame(const std::vector<uint8_t>& pixels, uint32_t width, uint32_t height, uint64_t stride) {
    ATCFrameV2 f{}; f.struct_size=sizeof(f); f.api_version=2;
    f.data=pixels.data(); f.byte_length=pixels.size(); f.width=width; f.height=height;
    f.row_stride=stride; f.pixel_format=ATC_PIXEL_FORMAT_GRAY8; return f;
}
static ATCGrayQualityV2 output() { ATCGrayQualityV2 q{}; q.struct_size=sizeof(q); q.api_version=2; return q; }
static ATCGrayQualityV2 quality(const std::vector<uint8_t>& pixels, uint32_t w, uint32_t h, uint64_t stride) {
    auto f=frame(pixels,w,h,stride); auto q=output(); CHECK(assess()(&f,&q)==ATC_OK); return q;
}
int main() {
    int passed=0, failed=0;
    auto test=[&](const char* name, const std::function<void()>& body) {
        try { body(); ++passed; } catch(const std::exception& e) { ++failed; std::cerr<<name<<": "<<e.what()<<'\n'; }
    };
    test("high-frequency textures survive coarse sampling aliases", [] {
        for (uint32_t width : {320u,480u,640u,1280u}) {
            const uint32_t height=width*3/4; std::vector<uint8_t> pixels(width*height);
            for (uint32_t y=0;y<height;++y) for(uint32_t x=0;x<width;++x) pixels[y*width+x]=(x+y)%2?255:0;
            const auto q=quality(pixels,width,height,width);
            CHECK(q.accepted && q.rejection_reason==ATC_GRAY_QUALITY_ACCEPTED);
            CHECK(q.policy_version==1 && q.sample_count>0 && q.sample_count<=160*160);
            CHECK(q.gray_standard_deviation>100 && q.laplacian_variance>8);
        }
    });
    test("blur texture and exposure have distinct stable reasons", [] {
        const uint32_t w=160,h=120; std::vector<uint8_t> pixels(w*h,0);
        CHECK(quality(pixels,w,h,w).rejection_reason==ATC_GRAY_QUALITY_TOO_DARK);
        std::fill(pixels.begin(),pixels.end(),255);
        CHECK(quality(pixels,w,h,w).rejection_reason==ATC_GRAY_QUALITY_TOO_BRIGHT);
        std::fill(pixels.begin(),pixels.end(),128);
        CHECK(quality(pixels,w,h,w).rejection_reason==ATC_GRAY_QUALITY_LOW_TEXTURE);
        for(uint32_t y=0;y<h;++y) for(uint32_t x=0;x<w;++x) pixels[y*w+x]=static_cast<uint8_t>(128+40*std::sin(x/15.0));
        const auto q=quality(pixels,w,h,w);
        CHECK(!q.accepted && q.rejection_reason==ATC_GRAY_QUALITY_BLURRED && q.gray_standard_deviation>=6);
    });
    test("nearest fourfold texture samples source block edges", [] {
        constexpr uint32_t w=640,h=480;std::vector<uint8_t> pixels(w*h);
        uint32_t random=123;std::vector<uint8_t> source(160*120);
        for(auto& value:source){random=random*1664525u+1013904223u;value=30+(random>>24)%196;}
        for(uint32_t y=0;y<h;++y)for(uint32_t x=0;x<w;++x)pixels[y*w+x]=source[(y/4)*160+x/4];
        const auto q=quality(pixels,w,h,w);
        CHECK(q.accepted&&q.laplacian_variance>=8&&q.sample_count<=160*160);
    });
    test("pitch padding is not image content", [] {
        constexpr uint32_t w=640,h=480,stride=672;
        std::vector<uint8_t> packed(w*h), padded((h-1)*stride+w,255);
        for(uint32_t y=0;y<h;++y) for(uint32_t x=0;x<w;++x) packed[y*w+x]=(x+y)%2?220:30;
        for(uint32_t y=0;y<h;++y) std::copy_n(packed.data()+y*w,w,padded.data()+y*stride);
        const auto a=quality(packed,w,h,w),b=quality(padded,w,h,stride);
        CHECK(a.accepted && b.accepted && a.sample_count==b.sample_count);
        CHECK(a.mean_intensity==b.mean_intensity && a.laplacian_variance==b.laplacian_variance);
    });
    test("invalid shape length overflow and format are rejected before dereference", [] {
        std::vector<uint8_t> pixels(16,128); auto f=frame(pixels,4,4,4); auto q=output(); auto fn=assess();
        f.byte_length=15; CHECK(fn(&f,&q)==ATC_INVALID_ARGUMENT && !q.accepted && q.sample_count==0);
        f=frame(pixels,4,4,3); q=output(); CHECK(fn(&f,&q)==ATC_INVALID_ARGUMENT);
        f=frame(pixels,4,4,UINT64_MAX); f.byte_length=UINT64_MAX; q=output(); CHECK(fn(&f,&q)==ATC_INVALID_ARGUMENT);
        f=frame(pixels,4,4,4); f.data=nullptr; q=output(); CHECK(fn(&f,&q)==ATC_INVALID_ARGUMENT);
        f=frame(pixels,4,4,4); f.width=8193; f.row_stride=8193; q=output(); CHECK(fn(&f,&q)==ATC_RESOURCE_LIMIT);
        f=frame(pixels,4,4,4); f.pixel_format=99; q=output(); CHECK(fn(&f,&q)==ATC_UNSUPPORTED_FORMAT);
    });
    test("POD prefix canaries and larger tails remain intact", [] {
        static_assert(sizeof(ATCGrayQualityV2)==48);
        std::vector<uint8_t> pixels(16,128); auto f=frame(pixels,4,4,4);
        struct Guard { uint32_t size=8,version=2; uint8_t tail[64]; } guard;
        std::fill(std::begin(guard.tail),std::end(guard.tail),0xA5);
        CHECK(assess()(&f,reinterpret_cast<ATCGrayQualityV2*>(&guard))==ATC_ABI_MISMATCH);
        for(auto value:guard.tail) CHECK(value==0xA5);
        auto q=output(); f.struct_size=8; CHECK(assess()(&f,&q)==ATC_ABI_MISMATCH && !q.accepted);
        CHECK(assess()(nullptr,&q)==ATC_INVALID_ARGUMENT);
    });
    std::cout<<"shared gray quality: "<<passed<<" passed, "<<failed<<" failed\n";
    return failed?1:0;
}
