# Local capture importer and diagnostic datasets

`tools/localization/import_scan.py` imports a local ScanDataExporter directory plus a closed map bundle into a new standalone replay directory. It copies `features.db`, the original JPEGs, `poses.json`, `intrinsics.json`, and optional scan manifest/evidence; every source copy and Gray8 frame carries SHA256. The dataset validator checks these references and includes their bytes in the dataset identity. Existing output directories are refused, and failed imports remove their own partial output.

JPEGs are decoded at their stored dimensions with Pillow `Image.convert('L')`, without resizing or EXIF rotation. Decoder/library versions are retained; the imports below used Pillow 12.3.0 with JPEG codec API version 6.2. Gray8 is tightly packed, so `rowStride=width`. A global calibration whose dimensions differ from the JPEG is rejected; a modern export uses its per-frame calibration and dimensions. The importer decodes the exact copied JPEG and rejects a source JSON copy whose hash differs from the bytes parsed earlier.

ARKit's column-major `worldFromARCamera` becomes row-major `worldFromOpticalCamera = worldFromARCamera * diag(1,-1,-1,1)`. The scan/world coordinates remain unchanged. Exported timestamp seconds become nanoseconds by decimal round-half-even conversion; ordering must remain strictly increasing. Dataset-local clock/camera/tracking identities default to zero, with per-frame modern `run` retained as the tracking epoch. The manifest explicitly records that the old files do not establish sensor exposure-reference or physical-camera clock mapping. These numeric ARKit trajectories are optional tracking data and are never labeled independent ground truth.

The current main-branch Swift exporter can emit a schema-v1 `manifest.json` with `coordinateSystem=arkit-world`, `matrixLayout=arkit-column-major`, metres, per-frame orientation, raster dimensions and intrinsics. The importer compares that manifest with `poses.json` and the actual decoded raster. Modern metadata alone does not verify rectification. A non-diagnostic import also requires `--rectification-evidence` containing an explicit verification method and the SHA256 of the exact source poses, global calibration, scan manifest, and every JPEG. Verification is supplied evidence, not inferred from the presence of intrinsics. Accepted stored-raster orientations are `landscapeLeft` and `landscapeRight`; reencoding is required for other orientations or nontrivial EXIF orientation.

An evidence JSON has this form (hash placeholders must be replaced with measured source hashes):

```json
{
  "verified": true,
  "method": "documented optical rectification/calibration procedure",
  "posesSha256": "64 lowercase hexadecimal characters",
  "intrinsicsSha256": "64 lowercase hexadecimal characters",
  "scanManifestSha256": "64 lowercase hexadecimal characters",
  "images": [
    {"path": "images/frame_0000.jpg", "sha256": "64 lowercase hexadecimal characters"}
  ]
}
```

Older directories without the complete per-frame export manifest require `--legacy-diagnostic`. Such imports always have `legacyDiagnostic=true`, `split=tune`, `rectification.verified=false`, and an explicit missing-metadata list. They cannot qualify for held-out promotion, even if positive labels or later evidence are supplied. `expectedMatch` defaults to `unknown`; a positive or negative label must be explicitly supplied by the caller. No ground-truth fields are generated.

## Captures imported on 2026-10-05

| Source under `unity_project/Assets/StreamingAssets` | Output under `/private/tmp/atc-local-data` | Frames | Stored/Gray8 dimensions | Match label | Capture time range (ns) |
|---|---|---:|---|---|---|
| `ScanData` | `scan-data/manifest.json` | 94 | 1920×1440 | positive, explicitly supplied for same-map diagnostic recognition | 1,073,061,666–47,564,131,166 |
| `ScanData_data1` | `scan-data1/manifest.json` | 64 | 1920×1440 | unknown | 161,076,249–31,666,345,333 |

Both imports copy `SLAMTestAssets/features.db`: 92 keyframes, 127,685 ORB features and 1,000 vocabulary words. Its SHA256 is `b07ff01c7871a61c644f043aae07c56d9df5d646428576a2d63bb3c12929feb1`. The bundle does not require the GLB to run Raw localization.

`ScanData` retains `(fx,fy,cx,cy)=(1606.4742,1606.4742,959.63696,721.1574)`. It has 44,435,506 original JPEG bytes and 259,891,200 Gray8 bytes. `ScanData_data1` retains `(1588.85,1588.85,959.5307,721.3)`, with 39,545,761 JPEG bytes and 176,947,200 Gray8 bytes. No image/K scaling was applied.

| Capture | poses.json SHA256 | intrinsics.json SHA256 | Dataset digest including copied provenance |
|---|---|---|---|
| 94-frame | `1b886e5cbdbd7bdafc48398e7ee58dfc952d96a13e98c30f9dbd9f3004dbe077` | `581b161806a39b21ed3fe758ba7d742be70c64b5f2513b1203daee782ed33946` | `a1097b9efd473c5b22936f68d6906e87ac64bcf8f3c106c74a03521d9a15146b` |
| 64-frame | `d87a77a0ec6f19e2447baba36faf161bd2e6537d189cd28ee805173afca8fa59` | `a0325b0a7f09082dd8152b12579b6b538332dcbaedcca358ed82ba90ae215fe0` | `896734a4f0c16175320d34678059359974c76b59a03f260892f693762aba6d37` |

The 94-frame capture is a same-map diagnostic input rather than an independent generalization set. The 64-frame capture has no demonstrated map correspondence and remains unknown, rather than being silently labeled negative. Both lack per-frame orientation/calibration, verified rectification and independent pose truth. Raw coverage and algorithm diagnostics may be inspected; these files cannot establish positioning accuracy, false-positive rate, commercial readiness or held-out promotion.

## Reproduce an import

Run from the implementation checkout root `/Users/dirui/.codex/worktrees/area-target-runtime-v2/Area-Target-Scanner` with a Python interpreter that has Pillow installed. Choose a fresh output path; the paths above already exist and the CLI refuses to overwrite them.

```sh
python3 tools/localization/import_scan.py \
  --source unity_project/Assets/StreamingAssets/ScanData \
  --map unity_project/Assets/StreamingAssets/SLAMTestAssets \
  --output /private/tmp/atc-local-data/new-scan-data \
  --dataset-id local-scan-data-94 --scene-id local-map-room \
  --capture-session-id scan-data-capture \
  --expected-match positive --legacy-diagnostic
```

The importer rejects duplicate JSON keys, image paths, indices and timestamps; path traversal and consumed symlinks; nonfinite/nonrigid poses or calibration; unclosed SQLite sidecars; mismatched actual dimensions; and exceeded frame, JSON, JPEG/Gray8 or total-byte limits. Limits are 10,000 frames, 4 MiB per JSON, 64 MiB per image, 8,192 pixels per dimension, 512 MiB map DB and 4 GiB total dataset. Inputs remain untouched.

TDD evidence: 18 initial tests failed because the importer was absent. Two added source-mutation regressions then failed for JPEG/metadata provenance races, the decoder-bomb CLI case failed before its error boundary was added, and a growing-JSON regression failed before bounded stream reads were enforced. The final importer suite covers these behaviors together with the schema-v1 modern evidence path, asymmetric pose conversion, resource rejection and cleanup. Native pipeline/device accuracy gates are separate.
