# Async Localization Pipeline Design

## Background

Currently `vl_process_frame` runs synchronously on Unity's main thread. The ORB pipeline takes ~10ms, and the AKAZE fallback adds another ~30-60ms (only when ORB fails, which is its way of saying "I give up, tag in the big guy"). While AKAZE rarely triggers during same-session tracking, moving the entire localization pipeline to a background thread eliminates any chance of main-thread stutter. Because nothing says "immersive AR experience" like a frozen frame.

## AKAZE Cost Analysis

### Offline (one-time)
- `build_feature_database()` extracts AKAZE descriptors and writes them to the `akaze_features` table
- AKAZE extraction is 3-5x slower than ORB, but it only runs once during database creation — patience is a virtue
- Stored in features.db, loaded at runtime via `vl_add_keyframe_akaze`

### Runtime
- When ORB succeeds: AKAZE sits on the bench, zero overhead
- When ORB fails (fallback triggered):
  - `akaze_->detectAndCompute()`: ~20-40ms (ARM64)
  - BFMatcher knnMatch x N candidate keyframes: ~5-15ms
  - PnP RANSAC + refinement: ~1-2ms
  - Total per fallback: ~30-60ms (the price of ORB's incompetence)

### Trigger Frequency
- Same-session tracking: ORB success rate > 95%, AKAZE almost never triggers
- Cross-session relocalization: ORB failure rate ~60%, those frames trigger AKAZE (ORB really doesn't handle change well)
- After cross-session lock-on: subsequent frames succeed via ORB nearby-KF search, AKAZE goes back to sleep

## Design: Background Thread Localization

### Architecture

```
Unity Main Thread (every frame Update):
  1. Copy current grayscale image + intrinsics + AR camera pose
  2. Submit to background thread (replace pending data, drop stale frames)
  3. Read latest result from background thread (if available)
  4. Update tracking state and pose

Background Thread (independent loop):
  1. Wait for new frame data
  2. vl_process_frame (ORB → AKAZE fallback → consistency filter → AT)
  3. Write result to shared variable
  4. Go to 1
```

Like a restaurant kitchen — the waiter (main thread) takes orders and serves food, the chef (background thread) does the actual cooking. Nobody wants the chef blocking the dining room door.

### C# Pseudocode

```csharp
class AsyncLocalizationRunner : IDisposable
{
    // Shared input (main thread writes, background thread reads)
    private byte[] _pendingImage;
    private float _pendingFx, _pendingFy, _pendingCx, _pendingCy;
    private float[] _pendingPose;
    private bool _hasPendingFrame;
    private readonly object _inputLock = new object();

    // Shared output (background thread writes, main thread reads)
    private VLResult _latestResult;
    private bool _hasNewResult;
    private readonly object _outputLock = new object();

    private Thread _workerThread;
    private volatile bool _running;

    public void SubmitFrame(byte[] grayImage, float fx, float fy,
                            float cx, float cy, float[] arPose)
    {
        lock (_inputLock)
        {
            // Deep copy — the main thread's camera buffer gets overwritten next frame,
            // and we'd rather not localize against yesterday's news
            if (_pendingImage == null || _pendingImage.Length != grayImage.Length)
                _pendingImage = new byte[grayImage.Length];
            Buffer.BlockCopy(grayImage, 0, _pendingImage, 0, grayImage.Length);

            _pendingFx = fx; _pendingFy = fy;
            _pendingCx = cx; _pendingCy = cy;

            if (_pendingPose == null) _pendingPose = new float[16];
            Array.Copy(arPose, _pendingPose, 16);

            _hasPendingFrame = true;
            Monitor.Pulse(_inputLock); // Wake up the background thread
        }
    }

    public bool TryGetResult(out VLResult result)
    {
        lock (_outputLock)
        {
            if (_hasNewResult)
            {
                result = _latestResult;
                _hasNewResult = false;
                return true;
            }
            result = default;
            return false;
        }
    }

    private void WorkerLoop()
    {
        while (_running)
        {
            byte[] image; float fx, fy, cx, cy; float[] pose;

            lock (_inputLock)
            {
                while (!_hasPendingFrame && _running)
                    Monitor.Wait(_inputLock);
                if (!_running) break;

                // Grab the latest frame (skip any queued stale frames — they had their chance)
                image = _pendingImage;
                fx = _pendingFx; fy = _pendingFy;
                cx = _pendingCx; cy = _pendingCy;
                pose = _pendingPose;
                _hasPendingFrame = false;
            }

            // Run the full localization pipeline on the background thread
            var result = NativeBridge.vl_process_frame(
                _handle, image, width, height, fx, fy, cx, cy, 1, pose);

            lock (_outputLock)
            {
                _latestResult = result;
                _hasNewResult = true;
            }
        }
    }
}
```

### Main Thread Usage

```csharp
void Update()
{
    // 1. Submit current frame
    _asyncRunner.SubmitFrame(currentGrayImage, fx, fy, cx, cy, arCameraPose);

    // 2. Read the previous result (living in the past, but only by 1-2 frames)
    if (_asyncRunner.TryGetResult(out var result))
    {
        if (result.state == 1) // TRACKING
        {
            UpdatePose(result.pose);
            _trackingState = TrackingState.Tracking;
        }
        else
        {
            _trackingState = TrackingState.Lost;
        }
    }
}
```

## Important Considerations

### Image Data
- Must deep-copy the image buffer — the main thread's camera buffer gets overwritten next frame
- Consider double-buffering to avoid per-frame allocation (because the GC has enough problems already)

### Frame Skipping
- The background thread only processes the latest frame, skipping any queued stale frames
- This prevents localization results from piling up and introducing ever-growing latency (a queue that only grows is just a memory leak with extra steps)

### Thread Safety
- `vl_process_frame` only reads keyframe data internally — thread-safe
- `vl_add_keyframe` / `vl_add_keyframe_akaze` / `vl_build_index` are called during initialization, never concurrent with processFrame
- `vl_set_alignment_transform` may be called at runtime — needs a lock or atomic flag

### Result Latency
- Localization results are delayed by 1-2 frames (~16-33ms @60fps)
- Minimal impact on AR experience — ARKit/ARCore tracking has similar latency anyway
- Can use Kalman filter or interpolation to smooth pose transitions

### No Need to Split ORB/AKAZE Across Threads
- ORB and AKAZE are sequential (AKAZE only runs when ORB fails — it's a fallback, not a parallel universe)
- Keeping them on the same background thread is simpler
- Splitting into two threads adds synchronization complexity for negligible benefit

## Implementation Roadmap

1. First validate AKAZE accuracy with the current synchronous approach
2. Once confirmed useful, implement async on the C# side (C++ native side needs no changes — it doesn't care who calls it)
3. Async changes mainly affect `LocalizationPipeline.cs` or a new `AsyncLocalizationRunner.cs`
4. For further optimization, consider throttling AKAZE fallback to every N frames (because even fallbacks need a cooldown)
