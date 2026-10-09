import Foundation
import simd

@MainActor
final class AreaTargetReplayAdapter: LocalizationReplayEngine {
    let identity: LocalizationAssetIdentity
    private let asset: AreaTargetSavedAsset
    private let engine: AreaTargetOfflineLocalizing
    private let recognitionMode: AreaTargetRecognitionMode
    private var generation = UUID()
    init(asset: AreaTargetSavedAsset, sourceFingerprint: String?, assetDigest: String? = nil,
         buildConfiguration: String? = nil, recognitionMode: AreaTargetRecognitionMode = .standard,
         engine: AreaTargetOfflineLocalizing = AreaTargetOfflineLocalizer()) {
        self.asset = asset; self.engine = engine
        self.recognitionMode = recognitionMode
        identity = Self.assetIdentity(asset: asset, sourceFingerprint: sourceFingerprint,
            assetDigest: assetDigest, buildConfiguration: buildConfiguration, recognitionMode: recognitionMode)
    }
    static func assetIdentity(asset: AreaTargetSavedAsset, sourceFingerprint: String?, assetDigest: String?,
                              buildConfiguration: String?, recognitionMode: AreaTargetRecognitionMode = .standard) -> LocalizationAssetIdentity {
        .init(provider: .areaTarget, assetID: asset.jobID, sourceFingerprint: sourceFingerprint,
              engineVersion: AreaTargetLocalizationSession.engineVersion,
              assetDigest: assetDigest, buildConfiguration: buildConfiguration, areaTargetRecognitionMode: recognitionMode)
    }
    func prepare() async throws -> Bool {
        let run = UUID(); generation = run
        do {
            _ = try await engine.load(url: asset.featuresURL)
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            try await engine.configure(mode: recognitionMode)
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            return true // Features and points already use original scan coordinates.
        } catch {
            if generation == run { engine.close() }
            throw error
        }
    }
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4? {
        await engine.localize(pixels: frame.pixels, width: frame.width, height: frame.height,
                              intrinsics: frame.intrinsics)?.cameraFromScan
    }
    func close() { generation = UUID(); engine.close() }
}

@MainActor
final class ImmersalReplayAdapter: LocalizationReplayEngine {
    let identity: LocalizationAssetIdentity
    private let mapURL: URL
    private let scanDirectory: URL
    private let engine: ImmersalOfflineLocalizing
    private var mapFromScan: simd_float4x4?
    private let fingerprint: (URL) async throws -> String
    private var generation = UUID()

    init(mapURL: URL, job: ImmersalMappingJob, scanDirectory: URL,
         engine: ImmersalOfflineLocalizing = ImmersalOfflineLocalizer(),
         fingerprint: @escaping (URL) async throws -> String = { directory in
             try await Task.detached(priority: .utility) { try ScanSourceFingerprint.compute(directory: directory) }.value
         }) {
        self.mapURL = mapURL; self.scanDirectory = scanDirectory; self.engine = engine; self.fingerprint = fingerprint
        identity = Self.assetIdentity(mapURL: mapURL, job: job)
    }
    static func assetIdentity(mapURL: URL, job: ImmersalMappingJob) -> LocalizationAssetIdentity {
        .init(provider: .immersal, assetID: "\(job.userID)/\(job.mapID ?? 0)",
              sourceFingerprint: job.sourceFingerprint, engineVersion: ImmersalLocalizationSession.engineVersion,
              assetDigest: ScanSourceFingerprint.valid(mapURL.deletingPathExtension().lastPathComponent) ? mapURL.deletingPathExtension().lastPathComponent : nil,
              buildConfiguration: LocalizationCoreMetadata.immersalCalibrationBuildConfiguration(
                base: "cloud-default;frames=\(job.frameCount);continuous-replay;no-ar-prior"))
    }
    func prepare() async throws -> Bool {
        let run = UUID(); generation = run
        func current() throws {
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
        }
        mapFromScan = nil
        _ = try await engine.load(url: mapURL)
        try current()
        do {
            let directory = scanDirectory
            let source = try await fingerprint(directory)
            try current()
            guard source == identity.sourceFingerprint else { throw ScanSourceFingerprint.Failure.changed }
            let frames = try await Task.detached(priority: .userInitiated) {
                try ImmersalAlignmentFrames.select(scanDirectory: directory)
            }.value
            try current()
            var candidates: [simd_float4x4] = []
            for frame in frames {
                try current()
                let pixels = try await ImmersalMeshOverlayPreparation.pixels(for: frame)
                try current()
                let result = await engine.localize(pixels: pixels, width: frame.width, height: frame.height, intrinsics: frame.intrinsics)
                try current()
                if let result, let candidate = ImmersalMeshAlignment.candidate(scanFromCamera: frame.scanFromCamera,
                    mapPosition: result.position, mapRotation: result.rotation) { candidates.append(candidate) }
            }
            let alignment = try ImmersalMeshAlignment.estimate(candidates).mapFromScan
            try current()
            mapFromScan = alignment
        } catch {
            try current()
            mapFromScan = nil // Retain raw recognition/latency without claiming common-frame stability.
        }
        // Calibration frames and the SDK's candidate/cache state never enter the graded run.
        engine.close()
        _ = try await engine.load(url: mapURL)
        try current()
        return mapFromScan != nil
    }
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4? {
        guard let result = await engine.localize(pixels: frame.pixels, width: frame.width, height: frame.height,
                                                intrinsics: frame.intrinsics),
              let cameraFromMap = ImmersalPose.worldFromMap(position: result.position, rotation: result.rotation,
                                                           worldFromCamera: matrix_identity_float4x4) else { return nil }
        return cameraFromMap * (mapFromScan ?? matrix_identity_float4x4)
    }
    func close() { generation = UUID(); engine.close(); mapFromScan = nil }
}
