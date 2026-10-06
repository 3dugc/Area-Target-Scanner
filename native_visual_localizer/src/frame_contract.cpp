#include "frame_contract.h"
#include <cmath>
#include <limits>
namespace atc {
ATCStatus validateConfig(const ATCConfigV2* c) {
    const auto abi=validatePod(c); if(abi!=ATC_OK) return abi;
    const auto cap=atc_default_config_v2();
    if(c->map_policy_version!=ATC_MAP_POLICY_VERSION ||
       c->map_coordinate_policy!=ATC_MAP_COORDINATE_LEGACY_SCAN_RH_METERS)
        return ATC_INVALID_ARGUMENT;
#define LIMIT(field) if(!c->field || c->field>cap.field) return ATC_INVALID_ARGUMENT
    LIMIT(max_image_bytes); LIMIT(max_dimension); LIMIT(max_database_bytes);
    LIMIT(max_keyframes); LIMIT(max_vocabulary_words); LIMIT(max_total_features);
    LIMIT(max_orb_features_per_keyframe); LIMIT(max_akaze_features_per_keyframe);
    LIMIT(max_bow_products); LIMIT(max_sql_steps); LIMIT(max_sql_time_ns);
#undef LIMIT
    return ATC_OK;
}
ATCStatus validateFrame(const ATCFrameV2* f, const ATCConfigV2& c) {
    const auto abi=validatePod(f); if(abi!=ATC_OK) return abi;
    if(f->pixel_format!=ATC_PIXEL_FORMAT_GRAY8) return ATC_UNSUPPORTED_FORMAT;
    if(!f->data || !f->width || !f->height || f->row_stride<f->width)
        return ATC_INVALID_ARGUMENT;
    if(f->width>c.max_dimension || f->height>c.max_dimension)
        return ATC_RESOURCE_LIMIT;
    if(!std::isfinite(f->fx) || !std::isfinite(f->fy) || !std::isfinite(f->cx) ||
       !std::isfinite(f->cy) || f->fx<=0 || f->fy<=0 ||
       f->cx<0 || f->cy<0 || f->cx>=f->width || f->cy>=f->height)
        return ATC_INVALID_ARGUMENT;
    const uint64_t rows=f->height-1;
    const uint64_t maximum=std::numeric_limits<uint64_t>::max();
    if(rows && f->row_stride>(maximum-f->width)/rows) return ATC_INVALID_ARGUMENT;
    const uint64_t minimum=rows*f->row_stride+f->width;
    if(f->byte_length<minimum) return ATC_INVALID_ARGUMENT;
    if(f->byte_length>c.max_image_bytes || minimum>c.max_image_bytes)
        return ATC_RESOURCE_LIMIT;
    if(minimum>std::numeric_limits<size_t>::max()) return ATC_RESOURCE_LIMIT;
    return ATC_OK;
}
}
