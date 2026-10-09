#pragma once
#include "area_target_runtime.h"
#include "visual_localizer_impl.h"
#include <memory>
namespace atc {
struct MapCandidate {
    ATCStatus status = ATC_MAP_INVALID;
    std::unique_ptr<VisualLocalizer> localizer;
    ATCMapInfoV2 info{}; // Loader fills counts/schema/policy; runtime assigns instance ID.
};
// Read-only bounded load. The candidate owns a fully indexed localizer on OK.
// A failure never mutates an existing runtime map. C ABI owns exception firewall.
MapCandidate loadMap(const char* bundle_directory, const ATCConfigV2& config);
}
