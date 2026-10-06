#include "visual_localizer.h"

// This executable is linked for iPhoneOS; device execution is a separate check.
int main() {
    VLHandle handle = vl_create();
    if (!handle) return 1;
    VLResult result{};
    vl_process_frame_out(handle, nullptr, 0, 0, 1, 1, 0, 0, 0, nullptr, &result);
    VLDebugInfo debug{};
    vl_get_debug_info(handle, &debug);
    vl_reset(handle);
    vl_destroy(handle);
    return result.state == 2 ? 0 : 2;
}
