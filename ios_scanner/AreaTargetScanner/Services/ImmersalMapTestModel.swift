import Foundation
import Combine

@MainActor
final class ImmersalMapTestModel: ObservableObject {
    let mapID: Int
    let userID: Int
    @Published private(set) var mapURL: URL?
    @Published private(set) var isDownloading = false
    @Published private(set) var isRestoring = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedReport: ImmersalLocalizationQualityReport?
    private let api: ImmersalMapDownloading
    private let store: ImmersalMapStore
    private let credentials: ImmersalCredentialStoring
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private static let diskQueue = DispatchQueue(label: "com.areatarget.immersal-map-files", qos: .utility)

    init(mapID: Int, userID: Int, api: ImmersalMapDownloading = ImmersalAPIClient(),
         store: ImmersalMapStore = ImmersalMapStore(), credentials: ImmersalCredentialStoring = ImmersalKeychainStore()) {
        self.mapID = mapID; self.userID = userID; self.api = api; self.store = store; self.credentials = credentials
        restore()
    }

    func restore() {
        guard !isDownloading else { return }
        let run = UUID(); generation = run; isRestoring = true
        let store = self.store, userID = self.userID, mapID = self.mapID
        operation = Task { [weak self] in
            do {
                let url = try await Self.onDisk { try store.mapURL(userID: userID, mapID: mapID) }
                let report = try await Self.readReport(url: url)
                guard let self, self.generation == run else { return }
                self.mapURL = url
                self.savedReport = report?.userID == userID && report?.mapID == mapID ? report : nil
                self.isRestoring = false; self.operation = nil
            } catch {
                guard let self, self.generation == run else { return }
                self.errorMessage = "本机地图无法读取，请重新下载地图。"
                self.isRestoring = false; self.operation = nil
            }
        }
    }

    func download() {
        guard !isDownloading, !isRestoring else { return }
        let run = UUID(); generation = run
        isDownloading = true; errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard let credential = try self.credentials.load(), credential.userID == self.userID else {
                    throw ImmersalAPIError.authentication
                }
                let data = try await self.api.downloadMap(mapID: self.mapID, token: credential.token)
                try Task.checkCancellation()
                guard self.generation == run else { return }
                guard try self.credentials.load() == credential else { throw ImmersalAPIError.authentication }
                let store = self.store, userID = self.userID, mapID = self.mapID
                let url = try await Self.onDisk { try store.save(data: data, userID: userID, mapID: mapID) }
                let report = try await Self.readReport(url: url)
                try Task.checkCancellation()
                guard self.generation == run else { return }
                guard try self.credentials.load() == credential else { throw ImmersalAPIError.authentication }
                self.mapURL = url
                self.savedReport = report?.userID == userID && report?.mapID == mapID ? report : nil
            } catch {
                guard self.generation == run else { return }
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
            guard self.generation == run else { return }
            self.isDownloading = false; self.operation = nil
        }
    }

    func cancelDownload() {
        generation = UUID(); operation?.cancel(); operation = nil; isDownloading = false; isRestoring = false
    }

    func save(_ report: ImmersalLocalizationQualityReport?) {
        guard let report, report.attemptCount > 0, report.mapID == mapID, report.userID == userID, let reportURL else { return }
        do {
            // Reports are small; atomic publication is synchronous so dismiss cannot lose a completed run.
            let data = try JSONEncoder().encode(report)
            try data.write(to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            savedReport = report
        } catch { errorMessage = "测试已结束，但报告保存失败：\(error.localizedDescription)" }
    }

    var reportURL: URL? { Self.reportURL(for: mapURL) }

    private nonisolated static func reportURL(for mapURL: URL?) -> URL? {
        mapURL?.deletingPathExtension().appendingPathExtension("quality.json")
    }

    private static func readReport(url: URL?) async throws -> ImmersalLocalizationQualityReport? {
        guard let url = reportURL(for: url) else { return nil }
        return try await onDisk {
            // A damaged report must not make a verified map unavailable offline.
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ImmersalLocalizationQualityReport.self, from: data)
        }
    }

    private static func onDisk<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            diskQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
