# Area Target Runtime v2 contract

C01, 2026-10-05. This document freezes the semantics for the M0/M1 synchronous runtime and its repeatable iOS evaluation. C02 realizes the layouts in `native_visual_localizer/include/area_target_runtime.h`; target-specific `sizeof`/`offsetof` checks remain authoritative for padding and pointer alignment. API version 2, asset schema compatibility and SDK release version are separate identities. This contract does not claim that future platform SDKs or calibration implementations exist.

## Coordinates and numeric transforms

`T_A_B` maps a point expressed in B into A: `p_A = T_A_B p_B`. Vectors are homogeneous column vectors; each public transform is a row-major `float[16]`, indexed `row*4+column`. Translations are meters. Storage order does not change multiplication order.

| Frame | Meaning |
|---|---|
| C | Right-handed rectified optical camera: x right, y down, z forward; it is the camera basis corresponding to the submitted pixels and K. |
| S | Original right-handed scan/map frame from a recognized producer. Keep its axes, origin and 3D points; do not normalize them a second time. |
| W | Canonical right-handed tracking world. The adapter explicitly converts the provider world, camera and physical-camera extrinsics into these bases. |

Raw localization returns `T_C_S` without AR/VIO priors. With valid tracking for that exposure, Session computes `T_W_S = T_W_C * T_C_S`, which places map content in tracking world. Each pose must be finite, have last row `[0,0,0,1]`, an orthonormal 3x3 rotation and determinant +1. Scale, shear, reflection and transposed affine matrices are invalid poses. Pose validation in native code permits floating-point tolerance; the exact golden data validator uses absolute tolerance `1e-6`.

Legacy `vl_*`, `VLResult` (76 bytes) and `VLDebugInfo` (48 bytes) remain unchanged. Their existing AR-camera result is distinct from optical C. Let `F = diag(1,-1,-1,1)`. Existing OpenCV-to-AR normalization left-multiplies by F exactly once: `T_AR_S = F*T_C_S`; v2 may recover optical output as `T_C_S = inverse(F)*T_AR_S`. Do not alter legacy output or re-transform database points.

A render/provider basis conversion must account for both domains. If `B_U_W` maps W coordinates into render world U and `B_M_S` maps S into imported mesh coordinates M, then `T_U_M = B_U_W*T_W_S*inverse(B_M_S)`. A basis may have determinant -1 when converting handedness; a pose within the same handedness remains rigid with determinant +1. Converting only translation Z, only the output basis, or only transposing is incorrect. The mesh import conversion must be recorded alongside the camera/world conversion.

The shared fixture uses asymmetric rotations and translations:

```text
T_W_C = [0 -1  0  3]   T_C_S = [ 0  0  1  1]
        [1  0  0 -2]           [ 0  1  0  0]
        [0  0  1  1]           [-1  0  0  2]
        [0  0  0  1]           [ 0  0  0  1]
T_W_S = [ 0 -1  0  3]
        [ 0  0  1 -1]
        [-1  0  0  3]
        [ 0  0  0  1]
```

C++, Swift, C# and Kotlin checks must consume `tests/fixtures/cross_platform/coordinate-contract-v2.json` rather than create separate identity-rotation examples. The fixture also uses different reflected world and mesh bases so a one-sided conversion cannot pass.

## RectifiedGray8 image input

`ATC_PIXEL_FORMAT_GRAY8=1` means **RectifiedGray8**, not an arbitrary camera luma plane. The adapter supplies one unsigned 8-bit intensity per pixel, top-to-bottom rows and left-to-right columns, after any required undistortion, crop, resize, orientation normalization and mirror removal. The frame has no orientation enum or distortion parameters: providing the correct rectified raster is a caller precondition. The fixture declares orientation explicitly so an undeclared orientation cannot masquerade as canonical input.

`width` and `height` are positive pixels; `row_stride` is bytes and must be at least width. Padding is allowed. The minimum readable range is `(height-1)*row_stride+width`; every multiply/add must be checked for overflow before reading. `byte_length` covers this range and does not exceed `max_image_bytes`; both dimensions do not exceed `max_dimension`. The runtime does not read row padding or retain the image pointer.

K is `[[fx,0,cx],[0,fy,cy],[0,0,1]]`, in submitted-image pixels. `fx/fy` must be finite and strictly positive; `cx/cy` must be finite and inside `[0,width)` / `[0,height)`. Pixel center `(0,0)` refers to the first pixel center. Positive-depth optical point `[2,1,4]` with `fx=600,fy=500,cx=320,cy=240` projects to `[620,365]`.

For raster transform H and camera basis rotation Q, `p_Crect=Q*p_Csource` and **`K_rect Q = H K_source`**. Source and rectified dimensions, raster orientation and optical basis must all be explicit. If C is rotated, tracking/extrinsics must describe it too: `T_W_Crect = T_W_Csource*inverse(Q)` in homogeneous form.

| Golden operation from 640x480 | Output size | Output `(fx,fy,cx,cy)` | Other required change |
|---|---|---|---|
| Nonuniform scale `(0.5,0.75)` | 320x360 | `(300,375,160,180)` | Scale both pixel axes; Q is identity. |
| Crop `(x=100,y=50,w=400,h=350)` | 400x350 | `(600,500,220,190)` | Subtract crop origin from principal point. |
| Clockwise 90 degrees | 480x640 | `(500,600,239,320)` | `(u',v')=(479-v,u)`; Q maps `(x,y,z)` to `(-y,x,z)`. Swapping focal lengths alone is insufficient. |
| Undo horizontal mirror | 640x480 | `(600,500,320,240)` | `(u',v')=(639-u,v)`; physical camera basis stays RH. |

The fixture's scale convention is `u'=sx*u,v'=sy*v`; a resampler with half-pixel offsets must use its actual H and adjust the principal point accordingly. Its mirrored **source** raster has generalized `fx=-600,cx=319`; that is adapter-side evidence, never a legal `ATCFrameV2`. Undo the mirror to obtain positive-focal RectifiedGray8. A mirror alone cannot be represented as a proper RH optical camera rotation.

Undistortion is an adapter operation. Zero-distortion handling requires explicit provider documentation or measured device evidence that its delivered image is already rectified. An SDK merely omitting distortion parameters is insufficient. This contract requires correct delivered pixels/K, without prescribing or depending on an unimplemented calibration API.

## Capture clock and tracking

All ABI timestamps are `uint64_t` nanoseconds in the declared session monotonic capture-clock epoch. Zero is a valid first timestamp. Frame ID, camera ID and epoch zero are also valid values, not missing-value sentinels. `camera_id` is an adapter-assigned uint64 identity for the physical image camera; preserve the provider string and calibration source in host diagnostics.

The adapter records the real sensor exposure timestamp, its documented exposure reference, source clock/epoch, the conversion to the host session monotonic clock and measured maximum mapping error. An affine mapping is `session_ns = round(scale*source_ns+offset_ns)` with positive scale; offsets and epochs are explicit. The fixture uses source epoch 7, session epoch 11, scale 1 and offset -900000000 ns. Never replace capture time with callback receipt, processing, delivery time or a synthesized increasing counter. A clock restart, discontinuity, tracking-origin change, camera/calibration change or source switch requires a reset boundary and a new relevant epoch. Numeric timestamps from different epochs are incomparable.

Live admission requires a known capture-clock mapping. Host ages use the same monotonic clock/epoch as mapped capture time: `submit_now-capture_ns` and `delivery_now-capture_ns` must both be nonnegative and at most `ATCSessionConfigV2.max_result_age_ns`. The host checks again at delivery because processing may make a previously fresh frame stale. This configuration is supplied once to both host admission and Session; the runtime does not guess a host clock epoch or sample a platform clock to infer age.

Session uses only supplied numeric capture times: ordering is strictly increasing, `alignment_age_ns=current_capture_ns-last_accepted_visual_alignment_capture_ns`, and `pose_skew_ns=abs(pose_timestamp_ns-capture_timestamp_ns)`. Alignment age must be nonnegative and at most `max_alignment_age_ns`; skew must be at most `max_pose_skew_ns`. Delivery age and alignment age are different quantities. The fixture checks 10 ms alignment age, 50 microseconds pose skew and 40 ms host delivery age independently.

Tracking is optional (`tracking=NULL`). Missing/invalid tracking does not invalidate an otherwise successful Raw recognition. It prevents new alignment; VIO propagation is separately marked and does not count as another visual success. In a positive alignment sample, tracking must match raw `frame_id`, `capture_timestamp_ns`, `map_generation`, `capture_clock_epoch` and `camera_id`, and carry a valid tracking epoch. Its matrix must represent the physical RGB camera at the exposure time, not a render camera or current head pose. For a head tracker H, the adapter supplies `T_W_C=T_W_H*T_H_C` using valid camera-specific extrinsics and the declared optical basis.

`clock_mapping_valid`, `pose_valid` and `extrinsics_valid` are uint32 flags restricted to 0/1. A true mapping flag asserts known clock/epoch conversion and that measured mapping uncertainty has been accounted for: `abs(pose_ns-capture_ns)+max_mapping_error_ns <= max_pose_skew_ns`. Session independently checks numeric skew; uncertainty/provenance are host diagnostics, not an extra native clock or hidden calibration dependency. A false flag, wrong physical camera, limited/unavailable tracking or identity mismatch retains Raw and reports a fusion rejection.

Interpolation is permitted only with measured mapped clocks, bracketing samples in the same epoch/world/camera/calibration, finite proper poses, normal tracking and an uncertainty/skew budget that passes policy. Use translation interpolation and SO(3) interpolation and record the supporting sample times. Do not extrapolate a current pose into the past to fill missing exposure tracking. When a provider cannot establish synchronized physical-camera pose, return Raw without alignment.

The validator rejects corrupted positive alignment fixtures, including unknown clock mappings and invalid extrinsics. This is evidence that the golden alignment is not valid; it does not mean runtime fusion rejection should erase a valid Raw pose.

## C ABI fields and units

Every public V2 struct begins with `uint32_t struct_size, api_version`, at offsets 0 and 4. Set `struct_size=sizeof(the actual struct)` and `api_version=2`, including output structs. The complete known layout is required; larger size may carry an unused tail, and the library reads/writes only known fields. Wrong version or short size returns `ATC_ABI_MISMATCH`. A too-small output must not be written past its advertised range; no valid output payload is promised for that error. C++ exceptions never cross the C ABI. There is no struct packing override or hardcoded cross-architecture pointer offset.

The header is the concrete encoding; fields below are fixed C01 semantics. All flags/enums/count settings are uint32 unless stated otherwise, all identities/times/byte ranges/count totals are uint64, and pose/K/quality numeric floats are 32-bit.

| Type | Fields after the common prefix |
|---|---|
| `ATCConfigV2` | uint64 `max_image_bytes`; uint32 `max_dimension,map_policy_version,map_coordinate_policy,max_keyframes,max_vocabulary_words,max_orb_features_per_keyframe,max_akaze_features_per_keyframe`; uint64 `max_database_bytes,max_total_features,max_bow_products,max_sql_steps,max_sql_time_ns`. All resource limits are positive. |
| `ATCFrameV2` | uint64 `frame_id,capture_timestamp_ns,map_generation,capture_clock_epoch,camera_id`; borrowed `const uint8_t* data`; uint64 `byte_length,row_stride`; uint32 `width,height,pixel_format`; float `fx,fy,cx,cy`. |
| `ATCMapInfoV2` | uint64 `map_instance_id,keyframe_count,orb_feature_count,akaze_feature_count,vocabulary_word_count`; uint32 `asset_schema_compatibility_id,map_coordinate_policy`. Counts describe the successfully published candidate. |
| `ATCResultV2` | int32 `status`; uint32 `raw_pose_valid`; the five Frame identity/time fields plus uint64 `map_instance_id`; float `camera_from_scan[16]`; uint32 `inliers`; float `confidence,reprojection_rmse_px`; uint32 `reprojection_error_valid`. |
| `ATCTrackingSampleV2` | The five Frame identity/time fields; uint64 `pose_timestamp_ns,tracking_epoch`; uint32 `clock_mapping_valid,pose_valid,extrinsics_valid,tracking_quality`; float `world_from_camera[16]`. |
| `ATCSessionConfigV2` | uint32 `window_size,initialization_samples,recovery_samples`; float `max_translation_residual_m,max_rotation_residual_rad`; uint64 `max_pose_skew_ns,max_alignment_age_ns,max_result_age_ns`; float `smoothing_tau_seconds`. |
| `ATCSessionResultV2` | int32 `status`; uint32 `raw_pose_valid,alignment_valid,propagated_pose_valid,state,mode,rejection_reason`; the five Frame identity/time fields plus uint64 `map_instance_id,tracking_epoch,alignment_age_ns`; float `camera_from_scan[16],world_from_scan[16]`. |

`confidence` is finite recognition support in `[0,1]`, not a calibrated probability; `inliers` is accepted visual correspondence count. `reprojection_rmse_px` is finite, nonnegative pixel RMSE only when `reprojection_error_valid=1`. Never interpret a matrix or metric whose validity flag is false. A valid output struct is initialized for each call; errors/no-match clear pose validity and cannot carry a stale successful pose into content updates.

Session counts are numbers of samples, translation residual is meters, SO(3) angle residual is radians, ages/skew are nanoseconds and smoothing tau is seconds (zero disables smoothing). Window, initialization and recovery counts are positive, with initialization/recovery no greater than window. Residual/age/skew limits are positive and finite; tau is finite and nonnegative. Configuration is explicit; there is no universal device accuracy default. Compare relative translations and SO(3) rotation residuals, never a mixed `||T_W_S-I||` scalar; changing world origin must not change acceptance.

Map policy version 1 defaults are frozen by `atc_default_config_v2()`:

| Limit | Default |
|---|---|
| Image bytes / each dimension | 64 MiB / 8192 pixels |
| Database bytes / keyframes / vocabulary | 512 MiB / 1000 / 4096 |
| Total features / ORB per keyframe / AKAZE per keyframe | 200000 / 2000 / 8192 |
| ORB-by-vocabulary products | 200000000 |
| SQL snapshot steps / SQL snapshot time budget | 20000000 / 3000000000 ns (3 s) |

The SQL budget covers snapshot parsing only. The database is closed before native BoW index construction; index work is bounded separately by the BoW product limit and its time is recorded as map loading, never frame localization latency.

Callers may tighten positive limits; values above these policy-v1 maxima are rejected. A separately reviewed policy/version change is required to relax compatibility limits. `map_coordinate_policy=ATC_MAP_COORDINATE_LEGACY_SCAN_RH_METERS=1` identifies the recognized legacy producer interpretation, and `asset_schema_compatibility_id=ATC_ASSET_SCHEMA_LEGACY_V1=1` reports its compatible schema. Unknown coordinate/schema/endianness policies are rejected. A valid feature map can localize without a GLB. Host-side ZIP, manifest and fingerprint validation stays outside core; the loader reads a local bundle and does not download or rewrite it.

| Status | Value | Meaning |
|---|---:|---|
| `ATC_OK` / `ATC_NO_MATCH` | 0 / 1 | Successful operation / valid visual request without recognition. |
| `ATC_INVALID_ARGUMENT` / `ATC_ABI_MISMATCH` | -1 / -2 | Invalid contract data / incorrect struct version or size. |
| `ATC_MAP_NOT_LOADED` / `ATC_MAP_INVALID` | -3 / -4 | No active map / invalid or unsupported candidate map. |
| `ATC_RESOURCE_LIMIT` / `ATC_INTERNAL_ERROR` | -5 / -6 | Configured budget exhausted / handled internal failure. |
| `ATC_STALE_FRAME` / `ATC_UNSUPPORTED_FORMAT` | -7 / -8 | Frame ordering or bound identity mismatch / unsupported pixel format. |

Tracking quality is `UNAVAILABLE=0,LIMITED=1,NORMAL=2`. Session state is `INITIALIZING=0,TRACKING=1,LOST=2`; mode is `NONE=0,RAW=1,ALIGNED=2,PROPAGATED=3`. Rejections are `NONE=0,NO_TRACKING=1,IDENTITY=2,CLOCK_MAPPING=3,TRACKING_INVALID=4,POSE_SKEW=5,OUTLIER=6,ALIGNMENT_AGE=7,STALE_FRAME=8,INVALID_RAW=9`, with `ATC_` prefixes as in the header. A rejected fusion can retain `raw_pose_valid=1`; status and validity are separate. Propagation uses existing alignment plus fresh tracking, keeps `raw_pose_valid=0` on no-match, and never refreshes the last visual alignment time.

## Buffer ownership, map identity and lifecycle

Core and Session calls are synchronous. Buffers/struct pointers are borrowed only until the call returns. The caller guarantees valid readable/writable memory, advertised capacity and stable pixels; the library cannot safely probe arbitrary dangling pointers. The host performs a bounded owned copy or pins a provider-owned buffer before submitting it to its single serial worker. One handle has one serial owner, one latest pending frame slot and no second native async queue. Replacing the pending frame releases its host-owned buffer; an in-flight frame remains alive until return. Independent sessions do not share mutable filter state.

`map_generation` is the host's logical request/cancellation generation; `map_instance_id` identifies the actual successfully loaded map instance and is returned with every Raw result. They are different fields. A successful map load/reset clears frame sequence binding. The first accepted localize binds `(map_generation,capture_clock_epoch,camera_id)`; subsequent frames require identical bound identity and strictly increasing `frame_id` **and** capture time. Any change requires explicit reset; otherwise return `ATC_STALE_FRAME`. Reset clears temporal state while retaining the active map; destroy releases it.

A failed map load may preserve the previous native map transactionally, but the requested new generation is unavailable. The host cannot keep using the old map while labeling frames/results with the failed generation. Explicit rollback requires a reset and explicit reactivation of the previous asset/instance under the chosen generation. Results must match the currently active generation, map instance and capture identity before they can affect content.

Lifecycle barrier order is fixed: stop accepting → increment generation → clear pending/output → wait for the in-flight synchronous call → reset/dispose → resume if appropriate. Backgrounding, permission change, device disconnection, camera/source change, map switch and tracking-origin reset use this boundary. The generation change suppresses an old result even if it finishes before the barrier completes. A Session tracking-epoch change clears existing alignment; a new pose is never combined with alignment from a previous origin.

Call reset/destroy only after in-flight work has completed on the owner. `void atc_destroy(ATCHandle*)` and `void atc_session_destroy(ATCSessionHandle*)` take a pointer to the handle, release and null it, and repeated destruction of a null handle is safe. A copied invalid handle or racing destroy/process is a caller contract violation. Failed, stale or invalid results cannot move content.

## Executable evidence

`tools/cross_platform/validate_contract.py` validates JSON data and recomputes pose composition, optical projection, both render bases, all four image/K cases, capture-clock mapping, host ages and numeric Session age/skew. It has no source-text assertions and does not prove camera calibration, feature localization accuracy, physical-device support or lifecycle implementation. Those are subsequent native/host/iOS evaluation gates.

```sh
/Users/dirui/Documents/Area-Target-Scanner/venv/bin/python -m pytest tests/cross_platform/test_coordinate_contract.py tests/phase1/test_scan_contract.py -q
/Users/dirui/Documents/Area-Target-Scanner/venv/bin/python tools/cross_platform/validate_contract.py tests/fixtures/cross_platform/coordinate-contract-v2.json
```

RED: the new suite reported 39 expected missing-contract/validator failures, with working dependencies. GREEN: 39 new tests and 12 existing phase1 coordinate tests passed; the CLI emitted the exact asymmetric `T_W_S` above and `[620,365]`. Tracking-null data passes as Raw-only evidence with `alignmentValid=false`. Tests reject missing units/orientation, nonrigid/nonfinite/transposed poses, wrong composition/bases, inconsistent image/K transformations, fabricated capture provenance, unknown clock mapping/epoch, invalid physical-camera synchronization and stale ages.

## Session bootstrap and pinned epoch rejection

Before an alignment is ready, initialization and LOST recovery require the configured number of mutually consistent candidates. A candidate outside the translation/rotation residual limits restarts the immature window with that candidate as a new seed; earlier incompatible candidates no longer count. This prevents the first false visual match from blocking recovery forever. No alignment is published until the initialization/recovery count is reached. After alignment is ready, outliers are rejected without replacing the valid anchor.

After explicit Session reset pins a tracking epoch, an input from another epoch is rejected before modifying the current alignment. For unpinned sessions a valid tracking-origin change still clears alignment. Epochs are identities; the core does not infer order from their numeric value. Hosts suppress late results using their generation/epoch barrier.
