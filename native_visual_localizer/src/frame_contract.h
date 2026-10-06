#pragma once
#include "area_target_runtime.h"
namespace atc {
ATCStatus validateConfig(const ATCConfigV2* config);
ATCStatus validateFrame(const ATCFrameV2* frame, const ATCConfigV2& config);
template<class T> ATCStatus validatePod(const T* pod) {
    if (!pod) return ATC_INVALID_ARGUMENT;
    if (pod->struct_size < sizeof(T) || pod->api_version != ATC_API_VERSION)
        return ATC_ABI_MISMATCH;
    return ATC_OK;
}
}
