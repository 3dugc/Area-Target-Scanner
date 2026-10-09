// Minimal C ABI for the pinned Immersal 2.4.0 library. See README.md beside this file.
#pragma once
#include <stddef.h>
typedef struct { float x, y, z; } ATSImmersalVector3;
typedef struct { float x, y, z, w; } ATSImmersalQuaternion;
typedef struct {
    int handle;
    ATSImmersalVector3 position;
    ATSImmersalQuaternion rotation;
    int confidence;
    double rmse;
} ATSImmersalLocalizeInfo;
_Static_assert(sizeof(ATSImmersalLocalizeInfo) == 48, "Immersal 2.4 result ABI mismatch");
_Static_assert(offsetof(ATSImmersalLocalizeInfo, rmse) == 40, "Immersal 2.4 rmse ABI mismatch");
int icvLoadMap(const void *buffer);
int icvFreeMap(int handle);
int icvPointsGetCount(int handle);
ATSImmersalLocalizeInfo icvLocalize(int n, int *handles, int width, int height,
                                  float *intrinsics, void *pixels, int channels,
                                  int solverType, float *rotation);
