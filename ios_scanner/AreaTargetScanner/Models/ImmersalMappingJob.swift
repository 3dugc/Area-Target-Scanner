import Foundation

struct ImmersalMappingJob: Codable, Equatable, Identifiable {
    enum Stage: Int { case preparation = 1, upload = 2, construction = 3 }
    enum Phase: String, Codable {
        case paused, uploading, workspaceConflict, captureUncertain
        case constructing, constructionUncertain, pending, processing, sparse, done, failed, abandoned

        var title: String {
            switch self {
            case .paused: return "已暂停"
            case .uploading: return "正在上传"
            case .workspaceConflict: return "工作区需要确认"
            case .captureUncertain: return "上传结果待确认"
            case .constructing: return "正在提交建图"
            case .constructionUncertain: return "建图提交结果待确认"
            case .pending: return "等待建图"
            case .processing: return "正在建图"
            case .sparse: return "稀疏重建阶段"
            case .done: return "建图完成"
            case .failed: return "建图失败"
            case .abandoned: return "已停止本机任务"
            }
        }
    }
    enum PendingOperation: String, Codable { case capture, clear, construct }

    let id: UUID
    let userID: Int
    let scanName: String
    let mapName: String
    let createdAt: Date
    var fingerprint = ""
    var sourceFingerprint: String?
    var frameCount = 0
    var uploadedCount = 0
    var phase: Phase = .paused
    var pendingOperation: PendingOperation?
    var mapID: Int?
    var message: String?
    var workspaceImageCount: Int?

    var displayName: String {
        let suffix = id.uuidString.replacingOccurrences(of: "-", with: "")
        guard mapName.hasSuffix(suffix), mapName.count > suffix.count else { return mapName }
        return String(mapName.dropLast(suffix.count))
    }

    var stage: Stage {
        switch phase {
        case .paused: return uploadedCount > 0 ? .upload : .preparation
        case .uploading: return .upload
        case .constructing, .constructionUncertain, .pending, .processing, .sparse, .done, .failed:
            return .construction
        case .workspaceConflict, .captureUncertain, .abandoned: return .preparation
        }
    }

    var needsSource: Bool { mapID == nil && ![.done, .failed, .abandoned].contains(phase) }
    var canResume: Bool { phase == .paused && pendingOperation == nil && mapID == nil }
    var canRestart: Bool { [.workspaceConflict, .captureUncertain].contains(phase) && mapID == nil }
    var canAbandon: Bool { needsSource }
    var shouldQuery: Bool { (mapID != nil && ![.done, .failed].contains(phase)) || pendingOperation == .construct }
}
