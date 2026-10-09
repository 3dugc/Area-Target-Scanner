import Foundation
import Darwin

/// Small, independent JSON reports. File names contain UUIDs only; fingerprints
/// never enter paths. Existing legacy Immersal quality files remain in their store.
final class LocalizationReportStore {
    static let maximumReportBytes = 1024 * 1024
    static let maximumHistoryCount = 200
    private let rootURL: URL
    private let validRoot: Bool
    private let parentDirectory: Int32
    private let rootComponents: [String]
    private let lock = NSLock()
    private struct Envelope: Codable {
        let schemaVersion: Int
        let id: UUID
        let report: LocalizationEvaluationReport
    }
    private struct Candidate { let name: String; let modified: Double }

    init(rootDirectory: URL? = nil) {
        let requested = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalizationReports", isDirectory: true)
        let standardized = requested.standardizedFileURL
        let parent = Self.canonicalParent(standardized.deletingLastPathComponent().path)
        validRoot = requested.isFileURL && standardized.path != "/" && parent != nil
        // Foundation may display /private/var as /var. POSIX realpath preserves the
        // canonical components required for an O_NOFOLLOW traversal.
        let anchor = parent?.anchor ?? standardized.deletingLastPathComponent().path
        rootComponents = (parent?.missing ?? []) + [standardized.lastPathComponent]
        rootURL = URL(fileURLWithPath: ([anchor] + rootComponents).joined(separator: "/"), isDirectory: true)
        // Start inside the app's accessible container. Walking from / through
        // system directories with openat is denied by the real iOS sandbox.
        parentDirectory = validRoot ? Darwin.open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
    }

    deinit { if parentDirectory >= 0 { Darwin.close(parentDirectory) } }

    @discardableResult
    func save(report: LocalizationEvaluationReport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard Self.valid(report) else { throw StoreError.invalidReport }
        let id = UUID()
        return try publish(Envelope(schemaVersion: 1, id: id, report: report), id: id, subdirectory: "reports")
    }

    func latest(identity: LocalizationAssetIdentity) throws -> LocalizationEvaluationReport? {
        lock.lock(); defer { lock.unlock() }
        return try findReport(identity:identity)?.report
    }
    func latestURL(identity: LocalizationAssetIdentity) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return try findReport(identity:identity)?.url
    }
    private func findReport(identity: LocalizationAssetIdentity) throws -> (report:LocalizationEvaluationReport,url:URL)? {
        guard let directory = try openDirectory("reports", create: false) else { return nil }
        defer { Darwin.close(directory) }
        var result: (report:LocalizationEvaluationReport,url:URL)?
        for candidate in try candidates(directory) {
            guard let bytes = try? read(candidate.name, directory: directory),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
                  envelope.schemaVersion == 1, Self.valid(envelope.report),
                  envelope.id.uuidString.lowercased() == candidate.name.dropLast(5).lowercased(),
                  envelope.report.identity == identity, envelope.report.date.timeIntervalSince1970.isFinite else { continue }
            if result == nil || envelope.report.date > result!.report.date {
                result = (envelope.report,rootURL.appendingPathComponent("reports").appendingPathComponent(candidate.name))
            }
        }
        return result
    }

    @discardableResult
    func save(comparison: LocalizationComparisonReport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard Self.valid(comparison) else { throw StoreError.invalidReport }
        return try publish(comparison, id: comparison.id, subdirectory: "comparisons")
    }

    func latestComparison(sourceFingerprint: String) throws -> LocalizationComparisonReport? {
        lock.lock(); defer { lock.unlock() }
        return try findComparison(sourceFingerprint:sourceFingerprint)?.report
    }
    func latestComparisonURL(sourceFingerprint: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return try findComparison(sourceFingerprint:sourceFingerprint)?.url
    }
    func latestComparison(identities: [LocalizationAssetIdentity], recordingID: UUID? = nil) throws -> LocalizationComparisonReport? {
        lock.lock(); defer { lock.unlock() }
        guard let source = identities.first?.sourceFingerprint else { return nil }
        return try findComparison(sourceFingerprint: source, identities: identities, recordingID: recordingID)?.report
    }
    func latestComparisonURL(identities: [LocalizationAssetIdentity], recordingID: UUID? = nil) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let source = identities.first?.sourceFingerprint else { return nil }
        return try findComparison(sourceFingerprint: source, identities: identities, recordingID: recordingID)?.url
    }

    @discardableResult
    func saveMarkdown(comparison: LocalizationComparisonReport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard Self.valid(comparison) else { throw StoreError.invalidReport }
        let bytes = Data(LocalizationBenchmarkAnalysis(comparison: comparison).markdown(comparison: comparison).utf8)
        guard bytes.count <= Self.maximumReportBytes,
              let directory = try openDirectory("comparisons", create: true) else { throw StoreError.invalidCache }
        defer { Darwin.close(directory) }
        let name = comparison.id.uuidString.lowercased() + ".md"
        let temporary = "." + UUID().uuidString.lowercased() + ".tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw StoreError.invalidCache }
        defer { Darwin.close(file); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { throw StoreError.invalidReport }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, pointer.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.invalidCache }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw StoreError.invalidCache }
        return rootURL.appendingPathComponent("comparisons").appendingPathComponent(name)
    }

    private func findComparison(sourceFingerprint: String, identities: [LocalizationAssetIdentity]? = nil, recordingID: UUID? = nil) throws -> (report:LocalizationComparisonReport,url:URL)? {
        guard let directory = try openDirectory("comparisons", create: false) else { return nil }
        defer { Darwin.close(directory) }
        var result: (report:LocalizationComparisonReport,url:URL)?
        for candidate in try candidates(directory) {
            guard let bytes = try? read(candidate.name, directory: directory),
                  let report = try? JSONDecoder().decode(LocalizationComparisonReport.self, from: bytes),
                  Self.valid(report),
                  report.id.uuidString.lowercased() == candidate.name.dropLast(5).lowercased(),
                  report.sourceFingerprint == sourceFingerprint,
                  identities.map({ report.matches(identities: $0) }) ?? true,
                  recordingID.map({ report.recording?.id == $0 }) ?? true, report.date.timeIntervalSince1970.isFinite else { continue }
            if result == nil || report.date > result!.report.date {
                result = (report,rootURL.appendingPathComponent("comparisons").appendingPathComponent(candidate.name))
            }
        }
        return result
    }

    /// Typed JSON alone cannot distinguish corrupt metrics from legitimate evidence.
    /// These invariants mirror the version-1 evaluator without trusting saved grades.
    private static func valid(_ report:LocalizationEvaluationReport) -> Bool {
        func nonnegative(_ value:Double) -> Bool { value.isFinite && value >= 0 }
        func optional(_ value:Double?) -> Bool { value.map(nonnegative) ?? true }
        func percentilePair(_ median:Double?,_ p95:Double?) -> Bool {
            guard (median == nil) == (p95 == nil),optional(median),optional(p95) else { return false }
            return median.map { $0 <= p95! + 1e-9 } ?? true
        }
        let t = report.thresholds
        guard report.scoreVersion == 1, report.date.timeIntervalSince1970.isFinite,
              report.attemptCount >= 0, report.successCount >= 0,report.successCount <= report.attemptCount,
              nonnegative(report.successRate),report.successRate <= 1,
              abs(report.successRate - (report.attemptCount == 0 ? 0 : Double(report.successCount)/Double(report.attemptCount))) < 1e-9,
              nonnegative(report.captureDuration),nonnegative(report.trackedTravelMeters),
              t.minimumAttemptCount > 0,nonnegative(t.minimumDurationSeconds),nonnegative(t.minimumTestedTravelMeters),
              nonnegative(t.minimumSuccessRate),t.minimumSuccessRate <= 1,
              nonnegative(t.maximumFirstSuccessSeconds),nonnegative(t.maximumP95LatencySeconds),
              nonnegative(t.maximumP95TranslationDeltaMeters),nonnegative(t.maximumP95RotationDeltaDegrees),
              percentilePair(report.medianLatencySeconds,report.p95LatencySeconds),
              percentilePair(report.medianTranslationDeltaMeters,report.p95TranslationDeltaMeters),
              percentilePair(report.medianRotationDeltaDegrees,report.p95RotationDeltaDegrees),
              optional(report.firstRecognitionCaptureOffset),optional(report.cumulativeAlgorithmSecondsToFirstRecognition),
              optional(report.firstRecognitionLatencySeconds) else { return false }
        guard (report.attemptCount == 0) == (report.p95LatencySeconds == nil) else { return false }
        if let rotation = report.p95RotationDeltaDegrees, rotation > 180 + 1e-6 { return false }
        if report.successCount == 0 {
            guard report.firstRecognitionCaptureOffset == nil,report.cumulativeAlgorithmSecondsToFirstRecognition == nil,
                  report.firstRecognitionLatencySeconds == nil,report.p95TranslationDeltaMeters == nil,
                  report.p95RotationDeltaDegrees == nil else { return false }
        } else {
            guard let offset = report.firstRecognitionCaptureOffset, offset <= report.captureDuration + 1e-6,
                  let cumulative = report.cumulativeAlgorithmSecondsToFirstRecognition,
                  let latency = report.firstRecognitionLatencySeconds,cumulative >= latency else { return false }
        }
        let hasStability = report.p95TranslationDeltaMeters != nil && report.p95RotationDeltaDegrees != nil
        guard (report.p95TranslationDeltaMeters == nil) == (report.p95RotationDeltaDegrees == nil),
              report.successCount >= 2 || !hasStability else { return false }
        let knownSource = !report.identity.assetID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
            !(report.identity.sourceFingerprint?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)
        if !knownSource { return report.eligibility == .unknownProvenance && report.score == nil }
        if !report.sampleSufficient { return report.eligibility == .insufficientSamples && report.score == nil }
        if report.successCount == 0 {
            return ScanSourceFingerprint.valid(report.identity.sourceFingerprint) && report.eligibility == .noRecognition && report.score == 0
        }
        if !hasStability {
            return report.score == nil && (report.eligibility == .missingCommonAlignment ||
                (report.successCount < 2 && report.eligibility == .insufficientSuccessfulPoses))
        }
        guard ScanSourceFingerprint.valid(report.identity.sourceFingerprint),report.eligibility == .eligible,
              let latency = report.p95LatencySeconds,let translation = report.p95TranslationDeltaMeters,
              let rotation = report.p95RotationDeltaDegrees else { return false }
        func component(_ measured:Double,_ reference:Double) -> Double { measured == 0 ? 1 : min(1,reference/measured) }
        let expected = Int((40*report.successRate + 20*component(latency,3) +
            20*component(translation,0.25) + 20*component(rotation,5)).rounded())
        return report.score == expected
    }

    private static func valid(_ report:LocalizationComparisonReport) -> Bool {
        guard report.schemaVersion == 1,report.date.timeIntervalSince1970.isFinite,
              ScanSourceFingerprint.valid(report.queryFingerprint),ScanSourceFingerprint.valid(report.sourceFingerprint),
              report.results.count == 2,report.executionOrder == report.results.map({ $0.identity.provider }),
              Set(report.executionOrder.map({ $0.rawValue })) == Set([LocalizationProvider.areaTarget.rawValue,LocalizationProvider.immersal.rawValue]),
              report.results.allSatisfy({ valid($0) && $0.timingMode == .recordedReplay && $0.identity.sourceFingerprint == report.sourceFingerprint }) else { return false }
        if let attempts = report.attempts {
            guard validAttempts(attempts, results: report.results) else { return false }
        }
        if let recording = report.recording {
            guard recording.schemaVersion == 1, recording.sourceFingerprint == report.sourceFingerprint,
                  recording.inputDigest == report.queryFingerprint,
                  recording.frameCount == report.results[0].attemptCount,
                  abs(recording.duration - report.results[0].captureDuration) < 1e-6,
                  recording.context.previewDroppedFrames >= 0,
                  recording.date.timeIntervalSince1970.isFinite else { return false }
        }
        if let analysis = report.analysis, analysis != LocalizationBenchmarkAnalysis(comparison: report) { return false }
        let first = report.results[0],second = report.results[1]
        return first.attemptCount == second.attemptCount && first.thresholds == second.thresholds &&
            abs(first.captureDuration-second.captureDuration) < 1e-6 && abs(first.trackedTravelMeters-second.trackedTravelMeters) < 1e-6
    }

    private static func validAttempts(_ attempts: [LocalizationReplayAttempt], results: [LocalizationEvaluationReport]) -> Bool {
        guard attempts.count <= 64, attempts.count == results.reduce(0, { $0 + $1.attemptCount }) else { return false }
        func close(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a - b) < 1e-6
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted(), rank = Double(values.count - 1) * fraction
            let lo = Int(floor(rank)), hi = Int(ceil(rank))
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
        }
        var previousBatch: [LocalizationReplayAttempt]?
        for result in results {
            let batch = attempts.filter { $0.provider == result.identity.provider }
            guard batch.count == result.attemptCount, batch.filter({ $0.poseReturned }).count == result.successCount,
                  batch.allSatisfy({ $0.sequence >= 0 && $0.captureOffsetSeconds.isFinite && $0.captureOffsetSeconds >= 0 &&
                      $0.latencySeconds.isFinite && $0.latencySeconds >= 0 }),
                  batch.first.map({ abs($0.captureOffsetSeconds) < 1e-9 }) ?? true else { return false }
            for (a, b) in zip(batch, batch.dropFirst()) {
                guard b.sequence > a.sequence, b.captureOffsetSeconds - a.captureOffsetSeconds >= 1.5 - 1e-9 else { return false }
            }
            guard close(batch.last?.captureOffsetSeconds ?? 0, result.captureDuration),
                  close(percentile(batch.map(\.latencySeconds), 0.5), result.medianLatencySeconds),
                  close(percentile(batch.map(\.latencySeconds), 0.95), result.p95LatencySeconds) else { return false }
            if let first = batch.firstIndex(where: { $0.poseReturned }) {
                guard close(batch[first].captureOffsetSeconds, result.firstRecognitionCaptureOffset),
                      close(batch[first].latencySeconds, result.firstRecognitionLatencySeconds),
                      close(batch.prefix(first + 1).reduce(0, { $0 + $1.latencySeconds }), result.cumulativeAlgorithmSecondsToFirstRecognition) else { return false }
            }
            if let previousBatch {
                guard previousBatch.map(\.sequence) == batch.map(\.sequence),
                      zip(previousBatch, batch).allSatisfy({ abs($0.captureOffsetSeconds - $1.captureOffsetSeconds) < 1e-9 }) else { return false }
            }
            previousBatch = batch
        }
        return true
    }

    private static func canonicalParent(_ path:String) -> (anchor: String, missing: [String])? {
        var current = path
        var missing = [String]()
        while true {
            if let pointer = realpath(current,nil) {
                let resolved = String(cString:pointer); free(pointer)
                return (resolved, Array(missing.reversed()))
            }
            guard errno == ENOENT, current != "/" else { return nil }
            let url = URL(fileURLWithPath:current)
            missing.append(url.lastPathComponent)
            current = url.deletingLastPathComponent().path
        }
    }

    private func publish<T: Encodable>(_ value: T, id: UUID, subdirectory: String) throws -> URL {
        let bytes: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(value)
        } catch { throw StoreError.invalidReport }
        guard !bytes.isEmpty, bytes.count <= Self.maximumReportBytes else { throw StoreError.invalidReport }
        guard let directory = try openDirectory(subdirectory, create: true) else { throw StoreError.invalidCache }
        defer { Darwin.close(directory) }
        let name = id.uuidString.lowercased() + ".json"
        let temporaryName = "." + UUID().uuidString.lowercased() + ".tmp"
        let file = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw StoreError.invalidCache }
        defer { Darwin.close(file); unlinkat(directory, temporaryName, 0) }
        try bytes.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { throw StoreError.invalidReport }
            var count = 0
            while count < raw.count {
                let written = Darwin.write(file, pointer.advanced(by: count), raw.count - count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw StoreError.invalidCache }
                count += written
            }
        }
        guard fsync(file) == 0, renameat(directory, temporaryName, directory, name) == 0 else { throw StoreError.invalidCache }
        // Sync the containing directory so an atomic publication survives interruption.
        guard fsync(directory) == 0 else { throw StoreError.invalidCache }
        let history = try candidates(directory).sorted { lhs, rhs in
            lhs.modified == rhs.modified ? lhs.name > rhs.name : lhs.modified > rhs.modified
        }
        for candidate in history.dropFirst(Self.maximumHistoryCount) {
            guard unlinkat(directory, candidate.name, 0) == 0 else { throw StoreError.invalidCache }
            if subdirectory == "comparisons" { _ = unlinkat(directory, String(candidate.name.dropLast(5)) + ".md", 0) }
        }
        return rootURL.appendingPathComponent(subdirectory, isDirectory: true).appendingPathComponent(name)
    }

    /// Walk only descendants of the accessible canonical parent with O_NOFOLLOW.
    /// Descriptors keep reads/writes anchored if another caller renames a folder.
    private func openDirectory(_ child: String, create: Bool) throws -> Int32? {
        guard validRoot, parentDirectory >= 0 else { throw StoreError.invalidCache }
        var directory = dup(parentDirectory)
        guard directory >= 0 else { throw StoreError.invalidCache }
        var ownsDirectory = true
        defer { if ownsDirectory { Darwin.close(directory) } }
        let components = rootComponents + [child]
        for component in components {
            var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(directory, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw StoreError.invalidCache }
                next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw StoreError.invalidCache }
            Darwin.close(directory); directory = next
        }
        ownsDirectory = false
        return directory
    }

    private func candidates(_ directory: Int32) throws -> [Candidate] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw StoreError.invalidCache }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw StoreError.invalidCache }
        defer { closedir(stream) }
        var results = [Candidate]()
        var visited = 0
        // Rewind because dup shares the original directory cursor.
        rewinddir(stream)
        while let entry = readdir(stream) {
            visited += 1
            guard visited <= 1000 else { throw StoreError.invalidCache }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { continue }
            results.append(Candidate(name: name, modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
        }
        return results
    }

    private func read(_ name: String, directory: Int32) throws -> Data {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StoreError.invalidCache }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumReportBytes else { throw StoreError.invalidCache }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { raw in
            guard let pointer = raw.baseAddress else { throw StoreError.invalidCache }
            var count = 0
            while count < raw.count {
                let received = Darwin.read(file, pointer.advanced(by: count), raw.count - count)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw StoreError.invalidCache }
                count += received
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(file, &extra, 1) == 0 else { throw StoreError.invalidCache }
        return data
    }

    private enum StoreError: LocalizedError {
        case invalidReport, invalidCache
        var errorDescription: String? {
            switch self {
            case .invalidReport: return "定位报告无法保存或超过允许的大小。"
            case .invalidCache: return "本机定位报告目录无法安全读取或保存。"
            }
        }
    }
}
