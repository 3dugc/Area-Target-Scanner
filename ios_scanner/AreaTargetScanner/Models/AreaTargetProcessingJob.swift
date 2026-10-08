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
    var mapCLAHE = false
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
        case id, scanDirectoryPath, displayName, createdAt, phase, profile, uvUnwrap, mapCLAHE, accepted
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
        let original = "profile=\(profile);uv_unwrap=\(uvUnwrap ? 1 : 0);\(preparation)"
        guard mapCLAHE else { return original }
        return original + ";map_clahe=1;map_clahe_clip_limit=2.0;map_clahe_tile_grid=8x8"
    }

    var needsSource: Bool { !accepted && ![.failed, .downloaded, .stopped].contains(phase) }
    var isPending: Bool { ![.downloaded, .failed, .stopped].contains(phase) }
    var canStopLocalTracking: Bool { isPending }
    var canResume: Bool { [.paused, .submissionUnknown].contains(phase) }
    var scanDirectory: URL { URL(fileURLWithPath: scanDirectoryPath, isDirectory: true) }
    var archiveURL: URL? { archivePath.map { URL(fileURLWithPath: $0) } }
}

extension AreaTargetProcessingJob {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        scanDirectoryPath = try values.decode(String.self, forKey: .scanDirectoryPath)
        displayName = try values.decode(String.self, forKey: .displayName)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        persistedServerOrigin = try values.decodeIfPresent(AreaTargetServerOrigin.self, forKey: .persistedServerOrigin)
        phase = try values.decode(AreaTargetTaskPhase.self, forKey: .phase)
        profile = try values.decode(String.self, forKey: .profile)
        uvUnwrap = try values.decode(Bool.self, forKey: .uvUnwrap)
        mapCLAHE = values.contains(.mapCLAHE) ? try values.decode(Bool.self, forKey: .mapCLAHE) : false
        accepted = try values.decode(Bool.self, forKey: .accepted)
        archivePath = try values.decodeIfPresent(String.self, forKey: .archivePath)
        archiveSHA256 = try values.decodeIfPresent(String.self, forKey: .archiveSHA256)
        sourceFingerprint = try values.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        clientPreparation = try values.decodeIfPresent(AreaTargetClientPreparation.self, forKey: .clientPreparation)
        transferProgress = try values.decode(Double.self, forKey: .transferProgress)
        detail = try values.decode(String.self, forKey: .detail)
        remote = try values.decodeIfPresent(AreaTargetRemoteJob.self, forKey: .remote)
        savedAsset = try values.decodeIfPresent(AreaTargetSavedAsset.self, forKey: .savedAsset)
    }
}
