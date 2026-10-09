import XCTest
import AVFoundation
import CoreVideo
@testable import AreaTargetScanner

final class LocalizationVideoRecorderTests: XCTestCase {
    func testEncodesActualH264MovieWithPortraitTransformAndZeroBasedTimestamp() async throws {
        let output = temporary(); defer { try? FileManager.default.removeItem(at: output) }
        let recorder = try LocalizationVideoRecorder(outputURL: output)
        for index in 0..<6 {
            recorder.append(pixelBuffer: try bgra(width: 64, height: 48, value: UInt8(40 + index * 20)), timestamp: 200 + Double(index) * 0.12)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let result = try await recorder.finish()
        XCTAssertEqual(result.url, output)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 64, height: 48))
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: CGSize(width: 64, height: 48)).applying(transform)
        XCTAssertGreaterThan(rect.height, rect.width)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        var count = 0, last = -Double.infinity
        while let sample = decoded.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if count == 0 { XCTAssertEqual(time, 0, accuracy: 0.002) }
            XCTAssertGreaterThan(time, last); last = time; count += 1
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(count, 2)
        let repeated = try await recorder.finish()
        XCTAssertEqual(repeated.url, output)
        recorder.append(pixelBuffer: try bgra(width: 64, height: 48, value: 255), timestamp: 210)
        let afterAppend = try await recorder.finish()
        XCTAssertEqual(afterAppend.url, output)
    }

    func testAcceptsARCameraYUVAndLimitsLongEdge() async throws {
        let output = temporary(); defer { try? FileManager.default.removeItem(at: output) }
        let recorder = try LocalizationVideoRecorder(outputURL: output)
        for index in 0..<3 {
            recorder.append(pixelBuffer: try yuv(width: 1920, height: 1440), timestamp: Double(index) * 0.15)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await recorder.finish()
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
        XCTAssertEqual(size.width / size.height, 4 / 3, accuracy: 0.002)
    }

    func testEmptyFinishAndCancelFailWithoutPublishingPreview() async throws {
        let empty = temporary(); defer { try? FileManager.default.removeItem(at: empty) }
        let recorder = try LocalizationVideoRecorder(outputURL: empty)
        do { _ = try await recorder.finish(); XCTFail("Empty movie accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        let cancelled = temporary(); defer { try? FileManager.default.removeItem(at: cancelled) }
        let active = try LocalizationVideoRecorder(outputURL: cancelled)
        active.append(pixelBuffer: try bgra(width: 64, height: 48, value: 20), timestamp: 1)
        active.cancel()
        do { _ = try await active.finish(); XCTFail("Cancelled movie accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
    }

    func testRejectsExistingFileAndSymlinkWithoutRemovingThem() throws {
        let existing = temporary(), link = temporary()
        defer { try? FileManager.default.removeItem(at: existing); try? FileManager.default.removeItem(at: link) }
        try Data([1, 2, 3]).write(to: existing)
        XCTAssertThrowsError(try LocalizationVideoRecorder(outputURL: existing))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        XCTAssertThrowsError(try LocalizationVideoRecorder(outputURL: link))
        XCTAssertEqual(try Data(contentsOf: existing), Data([1, 2, 3]))
    }

    func testBackpressureDropsFramesAndNeverRetainsUnboundedCameraBuffers() async throws {
        let output = temporary(); defer { try? FileManager.default.removeItem(at: output) }
        let recorder = try LocalizationVideoRecorder(outputURL: output)
        let image = try bgra(width: 1280, height: 960, value: 60)
        for index in 0..<1000 { recorder.append(pixelBuffer: image, timestamp: Double(index) * 0.12) }
        let result = try await recorder.finish()
        XCTAssertGreaterThan(result.droppedFrames, 0)
        XCTAssertLessThan(try Data(contentsOf: output).count, LocalizationRecordingStore.maximumVideoBytes)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("localization-preview-" + UUID().uuidString).appendingPathExtension("mp4") }
    private func bgra(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width { let offset = row * CVPixelBufferGetBytesPerRow(result) + column * 4; bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255 }
        }
        return result
    }
    private func yuv(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(result, 0)), 110, CVPixelBufferGetBytesPerRowOfPlane(result, 0) * height)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(result, 1)), 128, CVPixelBufferGetBytesPerRowOfPlane(result, 1) * height / 2)
        return result
    }
}
