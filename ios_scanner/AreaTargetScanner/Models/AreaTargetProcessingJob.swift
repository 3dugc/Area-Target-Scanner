import Foundation

enum AreaTargetTaskPhase: String, Codable {
    case preparing, uploading, submissionUnknown, processing, ready, downloading, downloaded, paused, failed, stopped

    var title: String {
        switch self {
        case .preparing: return "准备扫描数据"
        case .uploading: return "上传扫描数据"
        case .submissionUnknown: return "等待确认上传结果"
        case .processing: return "云端处理中"
        case .ready: return "处理完成，可下载"
        case .downloading: return "下载到本机"
        case .downloaded: return "已保存到本机"
        case .paused: return "本机上传已暂停"
        case .failed: return "任务未完成"
        case .stopped: return "已停止本机跟踪"
        }
    }
}

struct AreaTargetProcessingJob: Identifiable, Codable, Equatable {
    var id: String
    let scanDirectoryPath: String
    var displayName: String
    let createdAt: Date
    private let persistedServerOrigin: AreaTargetServerOrigin?
    var serverOrigin: AreaTargetServerOrigin { persistedServerOrigin ?? .legacy }
    var phase: AreaTargetTaskPhase = .preparing
    var profile = "fast"
    var uvUnwrap = true
    var accepted = false
    var archivePath: String?
    var archiveSHA256: String?
    var sourceFingerprint: String?
    var clientPreparation: AreaTargetClientPreparation?
    var transferProgress: Double = 0
    var detail = "正在准备扫描数据…"
    var remote: AreaTargetRemoteJob?
    var savedAsset: AreaTargetSavedAsset?

    enum CodingKeys: String, CodingKey {
        case id, scanDirectoryPath, displayName, createdAt, phase, profile, uvUnwrap, accepted
        case archivePath, archiveSHA256, sourceFingerprint, clientPreparation, transferProgress, detail, remote, savedAsset
        case persistedServerOrigin = "serverOrigin"
    }

    init(id: String, scanDirectoryPath: String, displayName: String, createdAt: Date,
         serverOrigin: AreaTargetServerOrigin? = nil) {
        self.id = id
        self.scanDirectoryPath = scanDirectoryPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.persistedServerOrigin = serverOrigin
    }

    var localizationBuildConfiguration: String {
        let preparation = clientPreparation?.identityConfiguration ?? "client_preparation=unrecorded"
        return "profile=\(profile);uv_unwrap=\(uvUnwrap ? 1 : 0);\(preparation)"
    }

    var needsSource: Bool { !accepted && ![.failed, .downloaded, .stopped].contains(phase) }
    var isPending: Bool { ![.downloaded, .failed, .stopped].contains(phase) }
    var canStopLocalTracking: Bool { isPending }
    var canResume: Bool { [.paused, .submissionUnknown].contains(phase) }
    var scanDirectory: URL { URL(fileURLWithPath: scanDirectoryPath, isDirectory: true) }
    var archiveURL: URL? { archivePath.map { URL(fileURLWithPath: $0) } }
}
