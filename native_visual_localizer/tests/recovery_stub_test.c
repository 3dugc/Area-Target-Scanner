#include "visual_localizer.h"
#include <stdio.h>
int main(void) {
    VLHandle handle=vl_create();
    if (!handle || vl_set_recovery_mode(handle,0)!=0 ||
        vl_set_recovery_mode(handle,1)!=0 || vl_set_recovery_mode(NULL,1)!=0) return 1;
    vl_destroy(handle);
    puts("simulator stub honestly reports unsupported recovery configuration");
    return 0;
}
