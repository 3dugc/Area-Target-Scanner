<p align="center">
  <h1 align="center">📐 Area Target Scanner</h1>
  <p align="center">
    The open-source, offline, no-cloud-required alternative to Vuforia Area Targets.<br/>
    Scan a room with your iPhone. Get a textured 3D mesh. Track it in Unity. That's it.
  </p>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#ios-scanner">iOS Scanner</a> •
  <a href="#processing-pipeline">Processing Pipeline</a> •
  <a href="#unity-plugin">Unity Plugin</a> •
  <a href="#web-ui">Web UI</a> •
  <a href="#license">License</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/python-3.10%2B-blue" alt="Python 3.10+"/>
  <img src="https://img.shields.io/badge/unity-6000.0%2B-green" alt="Unity 6+"/>
  <img src="https://img.shields.io/badge/iOS-16%2B-orange" alt="iOS 16+"/>
  <img src="https://img.shields.io/badge/license-Apache%202.0-lightgrey" alt="License"/>
  <img src="https://github.com/area-target-scanner/area-target-scanner/actions/workflows/ci.yml/badge.svg" alt="CI"/>
</p>

---

## What Is This?

You know how Vuforia lets you scan a physical space and then do AR stuff relative to it? Yeah, that — but you own every byte of data, nothing leaves your machine, and you don't need a license key that costs more than your rent.

**Area Target Scanner** is a fully offline pipeline for creating and tracking Area Targets:

1. **Scan** a room using LiDAR on an iPhone/iPad
2. **Process** the scan into a compact asset bundle (point cloud → mesh → texture → visual features)
3. **Track** the area in real-time inside Unity with 6DoF pose estimation

No cloud uploads. No API keys. No "please contact sales." Just code.

## Quickstart

```
iPhone (LiDAR scan)
       │
       ▼  ZIP export (mesh + images + poses)
Python Pipeline  ──or──  Web UI (drag & drop)
       │
       ▼  Asset bundle (mesh.glb + features.db + texture + manifest)
Unity Plugin (6DoF AR tracking)
```

### 1. Process a scan

```bash
# Install dependencies
pip install -r requirements.txt

# Run the pipeline on an exported scan
python -m processing_pipeline.cli --input ./scan_data --output ./asset_bundle --verbose
```

Or use Docker if you prefer not to install OpenCV on your machine like a civilized person:

```bash
docker compose up
# Then open http://localhost:8080 and drag in your ZIP
```

### 2. Use in Unity

```bash
# In your Unity project, add the package:
# Package Manager → Add package from disk → unity_plugin/AreaTargetPlugin/package.json
```

```csharp
var tracker = new AreaTargetTracker();
tracker.Initialize("/path/to/asset_bundle");

// Every frame:
TrackingResult result = tracker.ProcessFrame(cameraFrame);
if (result.State == TrackingState.TRACKING) {
    // result.Pose = 4x4 matrix, result.Confidence = [0..1]
    transform.SetPositionAndRotation(result.Pose.GetPosition(), result.Pose.rotation);
}
```

## How It Works


### The Pipeline (4 steps, all offline)

| Step | What Happens | Tech |
|------|-------------|------|
| **Input Validation** | Verify scan ZIP contains mesh, poses, images | — |
| **Model Optimization** | Simplify & optimize the 3D mesh | [3D-Model-Optimizer](https://github.com/3dugc/3D-Model-Optimizer) |
| **Feature Extraction** | Extract ORB + AKAZE features, build BoW vocabulary, compute 3D-2D correspondences | OpenCV, scikit-learn |
| **Asset Bundling** | Package mesh + texture + feature DB + manifest into a deployable bundle | SQLite, trimesh |

### The Tracker (runs in Unity at 60fps)

The Unity plugin performs visual localization each frame:

1. Extract ORB features from the camera image
2. Retrieve candidate keyframes via Bag-of-Words similarity
3. Match descriptors and solve PnP for 6DoF pose
4. If ORB matching fails, fall back to AKAZE feature matching for robustness
5. Apply temporal consistency filter to reject outlier poses
6. Smooth with a Kalman filter for stable tracking

No GPU compute shaders. No ML models. Just good old-fashioned computer vision that works on a potato.

## iOS Scanner

A native Swift app that uses ARKit + LiDAR to capture:
- Dense point clouds
- Camera poses (4×4 transforms)
- RGB keyframe images
- Camera intrinsics

Exports everything as a tidy ZIP you can feed straight into the pipeline.

**Requirements:** iPhone 12 Pro or newer (needs LiDAR), iOS 16+, Xcode 15+

```bash
open ios_scanner/AreaTargetScanner.xcodeproj
# Build & run on a LiDAR-equipped device
# Scan → Export → AirDrop the ZIP to your Mac
```

## Processing Pipeline

The Python pipeline turns raw scan data into a deployable asset bundle.

```bash
python -m processing_pipeline.cli --input ./scan_data --output ./asset_bundle --verbose
```

**Input** (from iOS scanner):
```
scan_data/
├── model.obj          # Textured mesh
├── model.mtl          # Material
├── texture.jpg        # Texture atlas
├── poses.json         # Camera poses (4×4, column-major)
└── images/            # Keyframe RGB images
```

**Output** (for Unity):
```
asset_bundle/
├── manifest.json      # Metadata, bounding box, version
├── model.glb          # Optimized mesh
├── texture_atlas.png  # Texture
└── features.db        # SQLite DB with ORB features + BoW vocabulary
```

**Dependencies:** Python 3.10+, Open3D, OpenCV, NumPy, scikit-learn, trimesh

## Unity Plugin

A UPM package (`com.areatarget.tracking` v1.3.0) that provides:

- `AreaTargetTracker` — main tracking interface
- `VisualLocalizationEngine` — ORB + AKAZE + BoW + PnP pipeline
- `KalmanPoseFilter` — 6DoF pose smoothing
- `AssetBundleLoader` — loads and validates asset bundles
- `FeatureDatabaseReader` — reads the SQLite feature DB
- `AlignmentTransformCalculator` — coordinate system alignment between scan and AR session
- `ExtendedDebugInfo` — real-time pipeline diagnostics (feature counts, match stats, AKAZE fallback status)
- AR Foundation integration for iOS/Android

**Requirements:** Unity 6000.0+, AR Foundation 6.0+

### Native Visual Localizer

For production performance, the plugin includes an optional C++ native library (`libvisual_localizer`) that replaces the managed C# localization path. Built with CMake, supports macOS/Windows/Linux/iOS/Android.

Key capabilities:
- ORB + BoW visual localization with PnP RANSAC
- AKAZE fallback when ORB matching is insufficient
- Temporal consistency filter to reject outlier frames
- Coordinate system alignment transform support
- Debug diagnostics API (`vl_get_debug_info`) for real-time pipeline introspection

```bash
# Build on macOS
cd native_visual_localizer && bash build_macos.sh

# Build for iOS (produces libvisual_localizer.a)
cd native_visual_localizer && bash build_ios.sh
```

## Web UI

Don't want to touch a terminal? Fair enough. There's a web interface.

```bash
docker compose up
# Open http://localhost:8080
```

Drag in a scan ZIP, watch the progress bar, download your asset bundle. It's that simple.

The web service runs Flask + the processing pipeline in Docker, with a separate model optimizer sidecar.

## Testing

This project is thoroughly tested because we believe in sleeping well at night.

```bash
# Python pipeline tests
python -m pytest tests/ -v

# Unity plugin tests (in Unity Editor)
# Window → General → Test Runner → EditMode → Run All

# iOS scanner tests (in Xcode)
# Product → Test (⌘U)
```

The test suite includes unit tests, integration tests, property-based tests (Hypothesis), cross-session localization tests, and performance benchmarks.

## Documentation

- [Async Localization Design](docs/async-localization-design.md) — architecture for non-blocking localization
- [Cross-Session Comparison Report](docs/cross-session-comparison-report.md) — localization accuracy across different scan sessions
- [iOS Device Test Guide](docs/ios-device-test-guide.md) — step-by-step guide for on-device testing

## Project Structure

```
.
├── ios_scanner/              # Swift — LiDAR scanning app
├── processing_pipeline/      # Python — scan → asset bundle
├── native_visual_localizer/  # C++ — high-perf visual localization (macOS/iOS/Android)
├── unity_plugin/             # C# — Unity AR tracking package
├── unity_project/            # Unity test project
├── web_service/              # Flask — drag-and-drop web UI
├── tests/                    # Python test suite (unit + property-based + cross-session)
├── docs/                     # Design docs & test reports
├── docker-compose.yml        # One-command deployment
└── GUIDE.md                  # Detailed setup & usage guide (中文)
```

## vs. Vuforia / Immersal

| | Vuforia | Immersal | This Project |
|---|---------|---------|-------------|
| Pricing | 💰 Commercial license | 💰 Free tier + paid plans | Free (Apache 2.0) |
| Cloud dependency | Required for scan processing | Required (cloud mapping) | Fully offline |
| Data ownership | Uploaded to PTC servers | Uploaded to Immersal cloud | Stays on your machine |
| Customizable | Nope | Nope | Fork it, break it, fix it |
| LiDAR scanning | Via Vuforia app | Via Immersal SDK | Native Swift app included |
| Unity integration | Proprietary SDK | Proprietary SDK | Open UPM package |
| Tracking quality | Production-grade | Production-grade | Good enough™ (and improving) |
| Multi-feature fallback | ORB only | Proprietary | ORB + AKAZE dual-feature pipeline |
| Cross-session support | Limited | Yes (cloud-merged maps) | Built-in cross-session localization |
| Offline mapping | No | No | Yes |

## Contributing

PRs welcome. If you find a bug, open an issue. If you fix a bug, you're a hero.

## License

[Apache License 2.0](LICENSE) — use it commercially, modify it, distribute it. Just don't blame us if your AR furniture app places a couch on the ceiling.
