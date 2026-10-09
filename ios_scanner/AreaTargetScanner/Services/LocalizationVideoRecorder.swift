import Foundation
import CoreVideo
import CoreImage
import AVFoundation
import Darwin

/// Local, silent preview only. Exact grayscale query frames remain the replay input.
/// append holds at most four camera pixel buffers and never waits for encoding.
final class LocalizationVideoRecorder: @unchecked Sendable {
    private static let maximumPendingBuffers = 4
    private static let minimumInterval = 0.1
    private let outputURL: URL
    private let writingURL: URL
    private let writingName: String
    private let outputName: String
    private let directory: Int32
    private let queue = DispatchQueue(label: "localization.preview.encoder", qos: .userInitiated)
    private let stateLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // These fields are protected by stateLock; all other mutable fields belong to queue.
    private var accepting = true
    private var cancelled = false
    private var pendingBuffers = 0
    private var lastEnqueuedTimestamp: Double?
    private var droppedFrames = 0
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var dimensions = CGSize.zero
    private var firstWrittenTimestamp: Double?
    private var frameCount = 0
    private var finishStarted = false
    private var completed: Result<(url: URL, droppedFrames: Int), Error>?
    private var completions: [CheckedContinuation<(url: URL, droppedFrames: Int), Error>] = []

    enum Failure: LocalizedError {
        case invalidOutput, empty, encoding, tooLarge, cancelled
        var errorDescription: String? {
            switch self {
            case .invalidOutput: return "测试录像临时目录无法安全写入。"
            case .empty: return "尚未录到可用视频画面，请重新录制。"
            case .encoding: return "测试录像编码失败，请重新录制。"
            case .tooLarge: return "本次测试视频超过 128 MiB 上限，请缩短录制。"
            case .cancelled: return "已取消测试录像。"
            }
        }
    }

    init(outputURL: URL) throws {
        let requested = outputURL.standardizedFileURL
        guard outputURL.isFileURL, requested.path != "/", !Self.unsafeSymlink(requested.path),
              let pointer = realpath(requested.deletingLastPathComponent().path, nil) else { throw Failure.invalidOutput }
        let parent = String(cString: pointer); free(pointer)
        let descriptor = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidOutput }
        var info = stat()
        guard fstatat(descriptor, requested.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else {
            Darwin.close(descriptor); throw Failure.invalidOutput
        }
        self.outputURL = outputURL
        outputName = requested.lastPathComponent
        writingName = ".localization-preview-" + UUID().uuidString.lowercased() + ".mp4"
        writingURL = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(writingName)
        directory = descriptor
    }

    deinit {
        writer?.cancelWriting()
        unlinkat(directory, writingName, 0)
        Darwin.close(directory)
    }

    func append(pixelBuffer: CVPixelBuffer, timestamp: Double) {
        stateLock.lock()
        guard accepting else { stateLock.unlock(); return }
        guard timestamp.isFinite, timestamp >= 0 else { droppedFrames += 1; stateLock.unlock(); return }
        if let previous = lastEnqueuedTimestamp {
            guard timestamp > previous else { droppedFrames += 1; stateLock.unlock(); return }
            // Intentional 10 fps sampling is not encoder backpressure.
            guard timestamp - previous >= Self.minimumInterval - 0.000001 else { stateLock.unlock(); return }
        }
        guard pendingBuffers < Self.maximumPendingBuffers else { droppedFrames += 1; stateLock.unlock(); return }
        pendingBuffers += 1; lastEnqueuedTimestamp = timestamp
        queue.async { [self, pixelBuffer] in
            defer { stateLock.lock(); pendingBuffers -= 1; stateLock.unlock() }
            guard !isCancelled(), completed == nil else { return }
            do { try encode(pixelBuffer: pixelBuffer, timestamp: timestamp) }
            catch { fail(error) }
        }
        stateLock.unlock()
    }

    func finish() async throws -> (url: URL, droppedFrames: Int) {
        stopAccepting()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let completed { continuation.resume(with: completed); return }
                completions.append(continuation)
                guard !finishStarted else { return }
                finishStarted = true
                guard !isCancelled() else { fail(Failure.cancelled); return }
                guard frameCount > 0, let writer, let input else { fail(Failure.empty); return }
                guard writer.status == .writing else { fail(writer.error ?? Failure.encoding); return }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        guard completed == nil else { return }
                        guard !isCancelled(), writer.status == .completed else { fail(writer.error ?? (isCancelled() ? Failure.cancelled : Failure.encoding)); return }
                        do {
                            try publish()
                            stateLock.lock(); let dropped = droppedFrames; stateLock.unlock()
                            complete(.success((outputURL, dropped)))
                        } catch { fail(error) }
                    }
                }
            }
        }
    }

    func cancel() {
        stateLock.lock(); accepting = false; cancelled = true; stateLock.unlock()
        queue.async { [self] in guard completed == nil else { return }; fail(Failure.cancelled) }
    }

    private func isCancelled() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }
    private func stopAccepting() { stateLock.lock(); accepting = false; stateLock.unlock() }
    private func dropped() { stateLock.lock(); droppedFrames += 1; stateLock.unlock() }

    private func configure(pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw Failure.encoding }
        let scale = min(1, 1280.0 / Double(max(width, height)))
        let outputWidth = max(2, Int(Double(width) * scale) / 2 * 2)
        let outputHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        dimensions = CGSize(width: outputWidth, height: outputHeight)
        let writer = try AVAssetWriter(outputURL: writingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth, AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                AVVideoExpectedSourceFrameRateKey: 10, AVVideoMaxKeyFrameIntervalKey: 10,
                AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]
        ])
        input.expectsMediaDataInRealTime = true
        // AR camera buffers are landscape. Store a playback transform so the movie
        // is displayed in portrait without an extra bitmap rotation per frame.
        if outputWidth > outputHeight { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(outputHeight), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth, kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferCGImageCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.encoding }
        writer.add(input)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        guard writer.startWriting() else { throw writer.error ?? Failure.encoding }
        writer.startSession(atSourceTime: .zero)
    }

    private func encode(pixelBuffer: CVPixelBuffer, timestamp: Double) throws {
        if writer == nil { try configure(pixelBuffer: pixelBuffer) }
        guard let writer, let input, let adaptor, writer.status == .writing else { throw self.writer?.error ?? Failure.encoding }
        guard input.isReadyForMoreMediaData else { dropped(); return }
        guard let pool = adaptor.pixelBufferPool else { throw Failure.encoding }
        var destination: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey as String: Self.maximumPendingBuffers] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, attributes, &destination)
        if status == kCVReturnWouldExceedAllocationThreshold { dropped(); return }
        guard status == kCVReturnSuccess, let destination else { throw Failure.encoding }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard !source.extent.isEmpty else { throw Failure.encoding }
        let resized = source.transformed(by: CGAffineTransform(scaleX: dimensions.width / source.extent.width, y: dimensions.height / source.extent.height))
        context.render(resized, to: destination, bounds: CGRect(origin: .zero, size: dimensions), colorSpace: colorSpace)
        let initial = firstWrittenTimestamp ?? timestamp
        let relative = timestamp - initial
        guard relative.isFinite, relative >= 0 else { dropped(); return }
        let time = CMTime(seconds: relative, preferredTimescale: 600)
        guard time.isValid, !time.isIndefinite, adaptor.append(destination, withPresentationTime: time) else { throw writer.error ?? Failure.encoding }
        firstWrittenTimestamp = initial; frameCount += 1
        var info = stat()
        if fstatat(directory, writingName, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_size > LocalizationRecordingStore.maximumVideoBytes { throw Failure.tooLarge }
    }

    private func publish() throws {
        let file = openat(directory, writingName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Failure.invalidOutput }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw Failure.encoding }
        guard info.st_size <= LocalizationRecordingStore.maximumVideoBytes else { throw Failure.tooLarge }
        guard fsync(file) == 0,
              renameatx_np(directory, writingName, directory, outputName, UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw Failure.invalidOutput }
    }

    private func fail(_ error: Error) {
        guard completed == nil else { return }
        stateLock.lock(); accepting = false; stateLock.unlock()
        writer?.cancelWriting()
        // Only the unique staging filename is removed; a caller-owned final path is never removed.
        unlinkat(directory, writingName, 0)
        complete(.failure(error))
    }
    private func complete(_ result: Result<(url: URL, droppedFrames: Int), Error>) {
        guard completed == nil else { return }
        completed = result
        let pending = completions; completions = []
        pending.forEach { $0.resume(with: result) }
    }
    private static func unsafeSymlink(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK, current.path != "/var", current.path != "/tmp" { return true }
            current = current.deletingLastPathComponent()
        }
        return false
    }
}
