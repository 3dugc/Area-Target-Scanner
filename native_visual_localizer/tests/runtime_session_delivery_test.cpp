#include "area_target_runtime.h"
#include <algorithm>
#include <cmath>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <limits>
#define CHECK(c) do { if (!(c)) throw std::runtime_error(#c); } while (0)
static constexpr uint64_t second=1000000000;
static ATCSessionConfigV2 config() {
    ATCSessionConfigV2 c{}; c.struct_size=sizeof(c); c.api_version=2;
    c.window_size=c.initialization_samples=c.recovery_samples=2;
    c.max_translation_residual_m=.25f; c.max_rotation_residual_rad=5*3.14159265358979323846/180;
    c.max_pose_skew_ns=50000000; c.max_alignment_age_ns=c.max_result_age_ns=3*second;
    c.smoothing_tau_seconds=2; return c;
}
static ATCSessionResultV2 output() { ATCSessionResultV2 o{}; o.struct_size=sizeof(o);o.api_version=2;return o; }
static void identity(float* m) { std::fill_n(m,16,0.f);m[0]=m[5]=m[10]=m[15]=1; }
struct Session {
    ATCSessionHandle h=nullptr;
    Session(const ATCSessionConfigV2& c=config()) { CHECK(atc_session_create(&c,&h)==ATC_OK); }
    ~Session() { atc_session_destroy(&h); }
    ATCSessionResultV2 update(uint64_t id, uint64_t capture, uint64_t arrival, float x=0, bool matched=true,
                            ATCStatus expected=ATC_OK,uint64_t pose_skew=0,uint32_t changed_identity=0) {
        ATCResultV2 r{};r.struct_size=sizeof(r);r.api_version=2;r.status=matched?ATC_OK:ATC_NO_MATCH;
        r.raw_pose_valid=matched;r.frame_id=id;r.capture_timestamp_ns=capture;r.map_generation=7;
        r.capture_clock_epoch=11;r.camera_id=2;r.map_instance_id=31;r.confidence=matched?.8f:0;
        if(changed_identity&1)++r.map_generation;if(changed_identity&2)++r.map_instance_id;
        if(changed_identity&4)++r.capture_clock_epoch;if(changed_identity&8)++r.camera_id;
        r.inliers=matched?50:0;identity(r.camera_from_scan);r.camera_from_scan[3]=x;
        ATCTrackingSampleV2 t{};t.struct_size=sizeof(t);t.api_version=2;t.frame_id=id;t.capture_timestamp_ns=capture;
        t.map_generation=r.map_generation;t.capture_clock_epoch=r.capture_clock_epoch;t.camera_id=r.camera_id;
        t.pose_timestamp_ns=capture+pose_skew;t.tracking_epoch=4;
        t.clock_mapping_valid=t.pose_valid=t.extrinsics_valid=1;t.tracking_quality=ATC_TRACKING_QUALITY_NORMAL;
        identity(t.world_from_camera);auto out=output();
        const auto fn=&atc_session_update_at;
        CHECK(fn(h,&r,&t,arrival,&out)==expected && out.status==expected);return out;
    }
    ATCSessionResultV2 poll(uint64_t now, ATCStatus expected=ATC_NO_MATCH) {
        auto out=output();const auto fn=&atc_session_poll;
        CHECK(fn(h,now,&out)==expected && out.status==expected);return out;
    }
    void ready() { CHECK(!update(0,10*second,10*second).alignment_valid);
        CHECK(update(1,115*second/10,115*second/10).alignment_valid); }
};
int main() {
    int passed=0,failed=0;
    auto test=[&](const char* name,const std::function<void()>& body) {
        try {body();++passed;} catch(const std::exception& e) {++failed;std::cerr<<name<<": "<<e.what()<<'\n';}
    };
    test("engineering profile is returned from the only core", [] {
        ATCSessionConfigV2 c{};c.struct_size=sizeof(c);c.api_version=2;
        const auto fn=&atc_get_default_session_config_v2;
        CHECK(fn(&c)==ATC_OK);CHECK(c.window_size==2&&c.initialization_samples==2&&c.recovery_samples==2);
        CHECK(c.max_translation_residual_m==.25f&&c.max_alignment_age_ns==3*second&&c.max_result_age_ns==3*second);
        CHECK(c.smoothing_tau_seconds==2.f&&c.max_pose_skew_ns==50000000);
    });
    test("two fresh candidates confirm latest then use time smoothing", [] {
        Session s;auto first=s.update(0,10*second,10*second);CHECK(first.state==ATC_SESSION_CANDIDATE&&!first.alignment_valid);
        auto confirmed=s.update(1,115*second/10,116*second/10,.1f);CHECK(confirmed.alignment_valid&&confirmed.state==ATC_SESSION_TRACKING);
        CHECK(std::fabs(confirmed.world_from_scan[3]-.1f)<1e-6);
        auto next=s.update(2,13*second,131*second/10,.2f);
        const float expected=.1f+.1f*(1-std::exp(-1.5/2));
        CHECK(std::fabs(next.world_from_scan[3]-expected)<1e-5);
    });
    test("poll expires stuck work without advancing visual identity", [] {
        Session s;s.ready();auto held=s.poll(13*second);CHECK(held.alignment_valid&&!held.raw_pose_valid&&held.frame_id==1);
        auto pending=s.update(2,125*second/10,132*second/10,.1f);CHECK(pending.alignment_valid);
        CHECK(s.poll(155*second/10).alignment_valid);
        auto expired=s.poll(155*second/10+1);CHECK(!expired.alignment_valid&&!expired.raw_pose_valid&&expired.state==ATC_SESSION_LOST);
    });
    test("late visual result never confirms and fresh same ID can still bind", [] {
        Session s;auto stale=s.update(0,10*second,13*second+1,0,true,ATC_STALE_FRAME);
        CHECK(!stale.raw_pose_valid&&!stale.alignment_valid&&stale.rejection_reason==ATC_REJECTION_RESULT_AGE);
        CHECK(!s.update(0,14*second,14*second).alignment_valid);
        CHECK(s.update(1,155*second/10,155*second/10).alignment_valid);
    });
    test("no match breaks candidate confirmation", [] {
        Session s;s.update(0,10*second,10*second);
        auto failed=s.update(1,11*second,11*second,0,false,ATC_NO_MATCH);CHECK(!failed.alignment_valid);
        auto next=s.update(2,12*second,12*second);CHECK(!next.alignment_valid&&next.state==ATC_SESSION_CANDIDATE);
    });
    test("failure hold deadline is exposure based and poll cannot refresh", [] {
        Session s;s.update(0,10*second,10*second);s.update(1,115*second/10,129*second/10);
        auto held=s.update(2,13*second,13*second,0,false,ATC_NO_MATCH);
        CHECK(held.alignment_valid&&!held.raw_pose_valid&&held.state==ATC_SESSION_DEGRADED);
        CHECK(s.poll(145*second/10).alignment_valid);
        CHECK(!s.poll(145*second/10+1).alignment_valid);
    });
    test("distant candidate needs reconfirmation and never blends the jump", [] {
        Session s;s.ready();auto candidate=s.update(2,13*second,13*second,3.f);
        CHECK(candidate.alignment_valid&&candidate.state==ATC_SESSION_DEGRADED&&candidate.world_from_scan[3]==0);
        auto confirmed=s.update(3,145*second/10,145*second/10,3.f);
        CHECK(confirmed.alignment_valid&&confirmed.state==ATC_SESSION_TRACKING&&confirmed.world_from_scan[3]==3.f);
    });
    test("unconfirmed candidates cannot extend an old alignment", [] {
        Session s;s.ready();s.update(2,13*second,13*second,5.f);s.update(3,145*second/10,145*second/10,-5.f);
        const auto expired=s.poll(145*second/10+1);CHECK(!expired.alignment_valid&&expired.state==ATC_SESSION_CANDIDATE);
    });
    test("expired candidate is not a second confirmation", [] {
        Session s;s.update(0,10*second,10*second);auto next=s.update(1,14*second,14*second);
        CHECK(!next.alignment_valid&&next.state==ATC_SESSION_CANDIDATE);
    });
    test("backwards delivery clock clears display and reset clears epochs", [] {
        Session s;s.ready();const auto invalid=s.poll(11*second,ATC_INVALID_ARGUMENT);
        CHECK(!invalid.alignment_valid&&invalid.rejection_reason==ATC_REJECTION_DELIVERY_CLOCK);
        CHECK(atc_session_reset(s.h,7,4)==ATC_OK);
        CHECK(!s.update(0,second,second).alignment_valid);CHECK(s.update(1,2*second,2*second).alignment_valid);
    });
    test("reset poll clears prior visual identity as well as alignment", [] {
        Session s;s.ready();CHECK(atc_session_reset(s.h,8,5)==ATC_OK);
        const auto out=s.poll(second);
        CHECK(!out.alignment_valid&&!out.raw_pose_valid&&out.frame_id==0&&out.capture_timestamp_ns==0);
        CHECK(out.map_generation==8&&out.tracking_epoch==5&&out.map_instance_id==0&&out.capture_clock_epoch==0&&out.camera_id==0);
    });
    test("every pending sample must remain fresh in configurable confirmation window", [] {
        auto c=config();c.window_size=c.initialization_samples=3;Session s(c);
        CHECK(!s.update(0,10*second,10*second).alignment_valid);
        CHECK(!s.update(1,12*second,12*second).alignment_valid);
        const auto next=s.update(2,14*second,14*second);
        CHECK(!next.alignment_valid&&next.state==ATC_SESSION_CANDIDATE);
    });
    test("rejected duplicate reversed and late visual frames preserve held display", [] {
        Session s;s.ready();
        const auto duplicate=s.update(1,12*second,12*second,5,true,ATC_STALE_FRAME);
        CHECK(duplicate.alignment_valid&&!duplicate.raw_pose_valid&&duplicate.world_from_scan[3]==0);
        const auto reversed=s.update(2,11*second,13*second,5,true,ATC_STALE_FRAME);
        CHECK(reversed.alignment_valid&&!reversed.raw_pose_valid);
        const auto late=s.update(2,10*second,131*second/10,5,true,ATC_STALE_FRAME);
        CHECK(late.alignment_valid&&!late.raw_pose_valid&&late.rejection_reason==ATC_REJECTION_RESULT_AGE);
        CHECK(s.poll(145*second/10).alignment_valid);CHECK(!s.poll(145*second/10+1).alignment_valid);
    });
    test("invalid raw and pose skew preserve anchor without refreshing exposure", [] {
        Session s;s.ready();auto raw=ATCResultV2{};raw.struct_size=sizeof(raw);raw.api_version=2;
        raw.status=ATC_OK;raw.raw_pose_valid=1;raw.frame_id=2;raw.capture_timestamp_ns=12*second;
        raw.map_generation=7;raw.map_instance_id=31;raw.capture_clock_epoch=11;raw.camera_id=2;
        raw.confidence=std::numeric_limits<float>::quiet_NaN();identity(raw.camera_from_scan);auto out=output();
        CHECK(atc_session_update_at(s.h,&raw,nullptr,12*second,&out)==ATC_INVALID_ARGUMENT);
        CHECK(out.alignment_valid&&!out.raw_pose_valid&&out.world_from_scan[3]==0);
        const auto skew=s.update(2,13*second,13*second,1,true,ATC_OK,50000001);
        CHECK(skew.alignment_valid&&!skew.propagated_pose_valid&&skew.world_from_scan[3]==0&&skew.rejection_reason==ATC_REJECTION_POSE_SKEW);
        CHECK(s.poll(145*second/10).alignment_valid);CHECK(!s.poll(145*second/10+1).alignment_valid);
    });
    test("rejected raw ABI preserves session display and expires on delivery time", [] {
        Session s;s.ready();ATCResultV2 raw{};raw.struct_size=sizeof(raw);raw.api_version=1;auto out=output();
        CHECK(atc_session_update_at(s.h,&raw,nullptr,12*second,&out)==ATC_ABI_MISMATCH);
        CHECK(out.alignment_valid&&!out.raw_pose_valid&&out.rejection_reason==ATC_REJECTION_INVALID_RAW);
        out=output();CHECK(atc_session_update_at(s.h,nullptr,nullptr,145*second/10+1,&out)==ATC_INVALID_ARGUMENT);
        CHECK(!out.alignment_valid&&out.state==ATC_SESSION_LOST);
    });
    test("foreign map generation clock and camera never expose old anchor under new identity", [] {
        for(uint32_t identity:{1u,2u,4u,8u}){
            Session s;s.ready();const auto rejected=s.update(2,12*second,12*second,5,true,ATC_STALE_FRAME,0,identity);
            CHECK(!rejected.alignment_valid&&!rejected.raw_pose_valid&&!rejected.propagated_pose_valid);
            const auto held=s.poll(12*second);CHECK(held.alignment_valid&&held.map_generation==7&&held.map_instance_id==31&&held.capture_clock_epoch==11&&held.camera_id==2);
            const auto accepted=s.update(2,13*second,13*second,.1f);CHECK(accepted.alignment_valid);
        }
    });
    test("foreign clock cannot mutate current session delivery clock or anchor", [] {
        Session s;s.ready();const auto rejected=s.update(2,second,second,5,true,ATC_STALE_FRAME,0,4);
        CHECK(!rejected.alignment_valid&&!rejected.raw_pose_valid&&rejected.rejection_reason==ATC_REJECTION_STALE_FRAME);
        CHECK(s.poll(12*second).alignment_valid);
    });
    test("configurable confirmation requires all fresh candidates to agree", [] {
        auto c=config();c.window_size=c.initialization_samples=3;Session s(c);
        CHECK(!s.update(0,10*second,10*second,0).alignment_valid);
        CHECK(!s.update(1,11*second,11*second,.2f).alignment_valid);
        const auto chain=s.update(2,12*second,12*second,.4f);
        CHECK(!chain.alignment_valid&&chain.state==ATC_SESSION_CANDIDATE);
    });
    std::cout<<"Session delivery/display: "<<passed<<" passed, "<<failed<<" failed\n";
    return failed?1:0;
}
