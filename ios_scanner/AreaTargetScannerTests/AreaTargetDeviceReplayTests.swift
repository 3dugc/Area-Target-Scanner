import XCTest
import CryptoKit
import simd
@testable import AreaTargetScanner

/// Opt-in software acceptance using the owner's existing, immutable recording.
/// No camera, cloud request, source rewrite or new independent capture.
@MainActor
final class AreaTargetDeviceReplayTests: XCTestCase {
    func testExistingDeviceRecordingReplaysEveryFrameWithStandardNative() async throws {
        guard ProcessInfo.processInfo.environment["AREA_TARGET_DEVICE_RECORDING_REPLAY"] == "1" else {
            throw XCTSkip("Enable the device replay explicitly on an iPhone with saved maps and recordings")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This acceptance test requires the owner's physical iPhone data")
        #else
        let jobs = try AreaTargetJobStore().load()
        let assets = AreaTargetAssetStore()
        let originalRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalizationRecordings", isDirectory: true)
        var selected: (LocalizationRecording, AreaTargetProcessingJob, AreaTargetSavedAsset)?
        for recording in try probes(in: originalRoot) {
            let candidates = jobs.filter { $0.sourceFingerprint == recording.sourceFingerprint && $0.savedAsset != nil }
                .sorted { $0.createdAt > $1.createdAt }
            for job in candidates {
                if let asset = try assets.asset(jobID: job.id) {
                    selected = (recording, job, asset)
                    break
                }
            }
            if selected != nil { break }
        }
        guard let (recording, job, asset) = selected else {
            throw XCTSkip("No verified saved recording and matching downloaded Area Target map")
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AreaTargetPhoneValidation", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copyRoot = root.appendingPathComponent("recording-copy", isDirectory: true)
        let copiedPackage = copyRoot.appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: copiedPackage, withIntermediateDirectories: true)
        let originalPackage = originalRoot.appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
        let bounds = ["manifest.json": 64 * 1024,
            "frames.bin": LocalizationQueryRecorder.maximumPixelBytes + 4096,
            "preview.mp4": LocalizationRecordingStore.maximumVideoBytes]
        var originalHashes: [String: String] = [:]
        for (name, maximum) in bounds {
            let source = originalPackage.appendingPathComponent(name)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  let size = values.fileSize, size <= maximum else {
                throw CocoaError(.fileReadCorruptFile)
            }
            originalHashes[name] = try sha256(source)
            try FileManager.default.copyItem(at: source, to: copiedPackage.appendingPathComponent(name))
        }
        // Store reads recover staging files. Run those reads only on our copy.
        let recordings = LocalizationRecordingStore(rootDirectory: copyRoot)
        let frames = try recordings.load(recording)
        XCTAssertEqual(frames.count, recording.frameCount)
        let digestBefore = try LocalizationRecordingStore.inputDigest(frames: frames)
        XCTAssertEqual(digestBefore, recording.inputDigest)
        let mapBefore = try sha256(asset.featuresURL)
        let journalURL = AreaTargetJobStore().url
        let journalBefore = try sha256(journalURL)
        let traceURL = root.appendingPathComponent("native-candidates.jsonl")
        let previousTrace = ProcessInfo.processInfo.environment["VL_DIAGNOSTIC_TRACE"]
        XCTAssertEqual(setenv("VL_DIAGNOSTIC_TRACE", traceURL.path, 1), 0)
        defer {
            if let previousTrace { setenv("VL_DIAGNOSTIC_TRACE", previousTrace, 1) }
            else { unsetenv("VL_DIAGNOSTIC_TRACE") }
        }
        let engine = AreaTargetOfflineLocalizer()
        defer { engine.close() }
        let featureCount = try await engine.load(url: asset.featuresURL)
        XCTAssertGreaterThan(featureCount, 0)
        try await engine.configure(mode: .standard)
        var observations: [[String: Any]] = []
        for (index, frame) in frames.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            let result = await engine.localize(pixels: frame.pixels, width: frame.width,
                height: frame.height, intrinsics: frame.intrinsics)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            var row: [String: Any] = ["ordinal": index, "sequence": frame.sequence,
                "returned": result != nil, "latencySeconds": elapsed]
            XCTAssertTrue(elapsed.isFinite && elapsed >= 0)
            if let result {
                let matrix = result.cameraFromScan
                let values = (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
                XCTAssertTrue(values.allSatisfy(\.isFinite))
                XCTAssertTrue((0...1).contains(result.confidence))
                XCTAssertGreaterThanOrEqual(result.matchedFeatures, 8)
                row["cameraFromScanColumnMajor"] = values
                row["confidence"] = result.confidence
                row["matchedFeatures"] = result.matchedFeatures
            }
            observations.append(row)
        }
        engine.close()
        await engine.waitUntilIdle()
        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        let events = try trace.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let endings = events.filter { $0["event"] as? String == "frame_end" }
        XCTAssertEqual(endings.count, frames.count)
        let mapAfter = try sha256(asset.featuresURL)
        let journalAfter = try sha256(journalURL)
        let digestAfter = try LocalizationRecordingStore.inputDigest(frames: recordings.load(recording))
        XCTAssertEqual(mapAfter, mapBefore)
        XCTAssertEqual(journalAfter, journalBefore)
        XCTAssertEqual(digestAfter, digestBefore)
        var originalHashesAfter: [String: String] = [:]
        for name in originalHashes.keys { originalHashesAfter[name] = try sha256(originalPackage.appendingPathComponent(name)) }
        XCTAssertEqual(originalHashesAfter, originalHashes)
        let report: [String: Any] = ["schemaVersion": 1, "scope": "physical-device software replay; no independent accuracy ground truth",
            "engineVersion": AreaTargetLocalizationSession.engineVersion, "recognitionMode": "standard",
            "hasARPrior": false, "recordingID": recording.id.uuidString.lowercased(),
            "inputDigest": digestBefore, "mapSHA256": mapBefore, "jobID": job.id,
            "plannedFrames": frames.count, "observedFrames": observations.count,
            "returnedFrames": observations.filter { $0["returned"] as? Bool == true }.count,
            "featureCount": featureCount, "sourceUnchanged": mapBefore == mapAfter && journalBefore == journalAfter && digestBefore == digestAfter && originalHashes == originalHashesAfter,
            "originalRecordingFilesSHA256": originalHashes,
            "candidateTraceScope": "all candidates actually attempted by standard native retrieval; not exhaustive all-reference matching",
            "nativeTraceSHA256": try sha256(traceURL), "frames": observations]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("recorded-replay.json"), options: .atomic)
        print("AREA_TARGET_DEVICE_REPLAY_EVIDENCE=Library/Caches/AreaTargetPhoneValidation/\(root.lastPathComponent)")
        #endif
    }

    private struct Probe: Decodable {
        struct Manifest: Decodable { let recording: LocalizationRecording }
        let manifest: Manifest
    }

    private func probes(in root: URL) throws -> [LocalizationRecording] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return try directories.compactMap { directory -> LocalizationRecording? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  id.uuidString.lowercased() == directory.lastPathComponent else { return nil }
            let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink == false else { return nil }
            let manifest = directory.appendingPathComponent("manifest.json")
            let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  let size = values.fileSize, size <= 64 * 1024,
                  let envelope = try? JSONDecoder().decode(Probe.self, from: Data(contentsOf: manifest)),
                  envelope.manifest.recording.id == id else { return nil }
            return envelope.manifest.recording
        }.sorted { $0.date > $1.date }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
