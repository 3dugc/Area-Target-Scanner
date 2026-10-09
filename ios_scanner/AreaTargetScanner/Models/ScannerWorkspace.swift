import Foundation
import Combine

enum ScannerPlatform: String, CaseIterable, Identifiable {
    case areaTarget, immersal
    var id: String { rawValue }
    var title: String { self == .areaTarget ? "Area Target" : "Immersal" }
    var symbol: String { self == .areaTarget ? "scope" : "globe" }
    var exportFormat: ScanExportFormat { self == .areaTarget ? .areaTarget : .immersal }
    var supportsCloudMapping: Bool { self == .immersal }
    var supportsAreaTargetProcessing: Bool { self == .areaTarget }
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case scan, records, process
    var id: String { rawValue }
    var title: String {
        switch self { case .scan: return "扫描"; case .records: return "记录"; case .process: return "处理" }
    }
    var symbol: String {
        switch self { case .scan: return "viewfinder"; case .records: return "list.bullet.rectangle"; case .process: return "gearshape" }
    }
}

struct LocalizationBenchmarkReadiness {
    enum State: Equatable {
        case noScan, checking, areaNotDownloaded, unknownSource, immersalNotCompleted
        case sourceMismatch, areaAssetMissing, immersalMapMissing, ready
    }
    let state: State
    var areaJob: AreaTargetProcessingJob?
    var immersalJob: ImmersalMappingJob?
    var canOpen: Bool { state == .ready && areaJob != nil && immersalJob != nil }
    var message: String {
        switch state {
        case .noScan: return "选择一个扫描场景，完成并下载两套地图后即可比较。"
        case .checking: return "正在核对两套本机地图与原扫描来源…"
        case .areaNotDownloaded: return "请先完成 Area Target 处理并下载到本机。"
        case .unknownSource: return "原扫描来源未记录或无效，请用同一份原扫描重新建图。"
        case .immersalNotCompleted: return "请用这个扫描完成 Immersal 建图并下载地图。"
        case .sourceMismatch: return "两套地图来自不同的原扫描，请用同一份原扫描重新建图。"
        case .areaAssetMissing: return "Area Target 本机文件尚未就绪或校验失败，请重新下载。"
        case .immersalMapMissing: return "Immersal 地图尚未下载或本机校验失败，请先下载地图。"
        case .ready: return "两套地图已下载，原扫描来源一致。录制一段新测试录像后即可比较。"
        }
    }
}

/// Navigation is independent of capture state. A platform is a presentation preference;
/// a selected scan always refers to the same underlying directory in either mode.
@MainActor
final class ScannerWorkspace: ObservableObject {
    @Published private(set) var platform: ScannerPlatform
    @Published private(set) var tab: WorkspaceTab
    @Published private(set) var selectedScanPath: String?
    private let preferences: UserDefaults?
    private static let platformKey = "scanner.selectedPlatform"

    init(preferences: UserDefaults? = .standard, platform: ScannerPlatform? = nil,
         tab: WorkspaceTab = .scan, selectedScanPath: String? = nil) {
        self.preferences = preferences
        self.platform = platform ?? preferences?.string(forKey: Self.platformKey).flatMap(ScannerPlatform.init(rawValue:)) ?? .areaTarget
        self.tab = tab
        self.selectedScanPath = selectedScanPath
    }

    @discardableResult
    func selectPlatform(_ value: ScannerPlatform, operationInProgress: Bool) -> Bool {
        guard !operationInProgress else { return false }
        platform = value
        preferences?.set(value.rawValue, forKey: Self.platformKey)
        return true
    }

    @discardableResult
    func selectTab(_ value: WorkspaceTab, operationInProgress: Bool) -> Bool {
        guard !operationInProgress else { return false }
        tab = value
        return true
    }

    @discardableResult
    func selectScan(_ path: String, operationInProgress: Bool = false) -> Bool {
        guard !operationInProgress else { return false }
        selectedScanPath = path
        tab = .process
        return true
    }

    static func comparisonJob(for area: AreaTargetProcessingJob, in jobs: [ImmersalMappingJob]) -> ImmersalMappingJob? {
        guard area.phase == .downloaded, area.savedAsset != nil, ScanSourceFingerprint.valid(area.sourceFingerprint) else { return nil }
        return jobs.filter { $0.phase == .done && $0.mapID != nil && $0.sourceFingerprint == area.sourceFingerprint }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The independent phone benchmark belongs to the selected capture, even when
    /// another capture happens to contain identical source files.
    static func benchmarkReadiness(for scanDirectoryPath: String?, areaJobs: [AreaTargetProcessingJob],
                                   immersalJobs: [ImmersalMappingJob],
                                   areaAssetReady: (AreaTargetSavedAsset) -> Bool,
                                   immersalMapReady: (ImmersalMappingJob) -> Bool) -> LocalizationBenchmarkReadiness {
        guard let scanDirectoryPath, !scanDirectoryPath.isEmpty else { return .init(state: .noScan) }
        let directory = URL(fileURLWithPath: scanDirectoryPath, isDirectory: true).standardizedFileURL
        guard let area = areaJobs.filter({
            $0.scanDirectory.standardizedFileURL == directory && $0.phase == .downloaded && $0.savedAsset != nil
        }).max(by: { $0.createdAt < $1.createdAt }) else { return .init(state: .areaNotDownloaded) }
        guard ScanSourceFingerprint.valid(area.sourceFingerprint) else {
            return .init(state: .unknownSource, areaJob: area)
        }
        let completed = immersalJobs.filter {
            $0.scanName == directory.lastPathComponent && $0.phase == .done && ($0.mapID ?? 0) > 0 && $0.userID >= 0
        }
        guard let immersal = comparisonJob(for: area, in: completed) else {
            let different = completed.contains {
                ScanSourceFingerprint.valid($0.sourceFingerprint) && $0.sourceFingerprint != area.sourceFingerprint
            }
            return .init(state: different ? .sourceMismatch : (completed.isEmpty ? .immersalNotCompleted : .unknownSource),
                areaJob: area)
        }
        guard let asset = area.savedAsset, asset.jobID == area.id, areaAssetReady(asset) else {
            return .init(state: .areaAssetMissing, areaJob: area, immersalJob: immersal)
        }
        guard immersalMapReady(immersal) else {
            return .init(state: .immersalMapMissing, areaJob: area, immersalJob: immersal)
        }
        return .init(state: .ready, areaJob: area, immersalJob: immersal)
    }

    func didDeleteScan(_ path: String) {
        if selectedScanPath == path { selectedScanPath = nil }
    }
}
