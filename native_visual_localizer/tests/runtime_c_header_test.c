#include "area_target_runtime.h"
#include <stddef.h>
_Static_assert(offsetof(ATCFrameV2, struct_size) == 0, "size prefix");
_Static_assert(offsetof(ATCFrameV2, api_version) == 4, "version prefix");
_Static_assert(sizeof(ATCStatus) == 4, "status width");
int main(void) {
    ATCConfigV2 config = atc_default_config_v2();
    ATCHandle handle = NULL;
    if (atc_get_api_version() != ATC_API_VERSION) return 1;
    if (config.struct_size != sizeof(config) || config.api_version != 2) return 2;
    if (atc_create(&config, &handle) != ATC_OK || handle == NULL) return 3;
    atc_destroy(&handle);
    if (handle != NULL) return 4;
    atc_destroy(&handle);
    return 0;
}
