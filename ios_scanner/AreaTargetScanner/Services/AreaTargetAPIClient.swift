import Foundation
import CryptoKit
import Security

/// Durable routing identity. Unknown values fail decoding; callers cannot supply arbitrary hosts.
enum AreaTargetServerOrigin: String, Codable, CaseIterable {
    case legacy, current

    var baseURL: URL {
        switch self {
        case .legacy: return URL(string: "https://area-target.p.01xr.com")!
        case .current: return URL(string: "https://at.3dugc.com")!
        }
    }

    func allows(_ url: URL) -> Bool {
        let allowedQuery = url.query == nil || (url.path == "/api/v1/processing-requirements" &&
            url.query == "policy=mobile-scan-preparation-v2")
        return url.scheme == "https" && url.host == baseURL.host && url.port == nil &&
        url.user == nil && url.password == nil && allowedQuery && url.fragment == nil
    }
}

enum AreaTargetRemoteStatus: String, Codable { case queued, extracting, processing, completed, failed }

/// Only the opaque service session is persisted. The login password is never retained.
struct AreaTargetServiceSession: Codable, Equatable {
    let token: String
    let username: String
    let expiresAt: Date
    let csrfToken: String

    var isUsable: Bool {
        AreaTargetFileSafety.isLowerHex64(token) && !username.isEmpty && username.count <= 128 &&
        !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        !csrfToken.isEmpty && csrfToken.utf8.count <= 128 &&
        expiresAt.timeIntervalSince1970.isFinite && expiresAt > Date()
    }
}

protocol AreaTargetServiceSessionStoring {
    func load(origin: AreaTargetServerOrigin) throws -> AreaTargetServiceSession?
    func save(_ session: AreaTargetServiceSession, origin: AreaTargetServerOrigin) throws
    func remove(origin: AreaTargetServerOrigin) throws
}

final class AreaTargetServiceKeychainStore: AreaTargetServiceSessionStoring {
    private let service: String
    init(service: String = "com.areatarget.scanner.service-session") { self.service = service }

    private func query(_ origin: AreaTargetServerOrigin) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin.baseURL.host!,
         kSecAttrSynchronizable as String: false]
    }

    func load(origin: AreaTargetServerOrigin) throws -> AreaTargetServiceSession? {
        var attributes = query(origin)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let session = try? JSONDecoder().decode(AreaTargetServiceSession.self, from: data) else {
            throw AreaTargetAPIError.credentialStorage
        }
        return session
    }

    func save(_ session: AreaTargetServiceSession, origin: AreaTargetServerOrigin) throws {
        guard session.isUsable else { throw AreaTargetAPIError.invalidResponse }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = query(origin)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let result = status == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : status
        guard result == errSecSuccess else { throw AreaTargetAPIError.credentialStorage }
    }

    func remove(origin: AreaTargetServerOrigin) throws {
        let status = SecItemDelete(query(origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AreaTargetAPIError.credentialStorage }
    }
}

struct AreaTargetAPIProblem: Codable, Equatable {
    let code: String
    let message: String
    let retryable: Bool
}

struct AreaTargetResult: Codable, Equatable {
    let format: String
    let filename: String
    let sizeBytes: Int64
    let sha256: String
    let url: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case format, filename, sha256, url
        case sizeBytes = "size_bytes", expiresAt = "expires_at"
    }
}

struct AreaTargetRemoteJob: Codable, Equatable {
    let jobID: String
    let status: AreaTargetRemoteStatus
    let progress: Int
    let stage: String
    let message: String
    let profile: String
    let uvUnwrap: Bool
    let createdAt: Date
    let finishedAt: Date?
    let expiresAt: Date?
    let error: AreaTargetAPIProblem?
    let result: AreaTargetResult?
    enum CodingKeys: String, CodingKey {
        case status, progress, stage, message, profile, error, result
        case jobID = "job_id", uvUnwrap = "uv_unwrap", createdAt = "created_at"
        case finishedAt = "finished_at", expiresAt = "expires_at"
    }
}

private struct CriticalProtectionKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// JSONDecoder accepts 1.0 as Int. Check the new extension before token types
/// are lost so remote requirements, ZIPs, and journals match the server contract.
enum AreaTargetCriticalProtectionJSON {
    private enum ValidationError: Error { case malformed }

    static func validateRequirements(_ document: [String: Any]) throws {
        guard document.keys.contains("criticalFrameProtection") else { return }
        guard document["policy"] as? String == "mobile-scan-preparation-v2",
              let fields = document["criticalFrameProtection"] as? [String: Any],
              Set(fields.keys) == ["version", "riskVersion", "maximumProtectedFrames", "maximumProtectedLongEdge", "sharpnessThreshold", "contrastThreshold"],
              ["maximumProtectedFrames", "maximumProtectedLongEdge", "sharpnessThreshold", "contrastThreshold"].allSatisfy({ isInteger(fields[$0]) }) else {
            throw ValidationError.malformed
        }
    }

    static func validatePreparation(_ document: [String: Any]) throws {
        guard document.keys.contains("criticalFrameProtection") else { return }
        guard let fields = document["criticalFrameProtection"] as? [String: Any],
              Set(fields.keys) == ["version", "riskVersion", "protectedIndices", "candidateFrameCount"],
              isInteger(fields["candidateFrameCount"]), let indices = fields["protectedIndices"] as? [Any],
              indices.allSatisfy({ isInteger($0) }) else { throw ValidationError.malformed }
    }

    private static func isInteger(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
        return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType))
    }
}

struct AreaTargetCriticalFrameProtectionCapability: Codable, Equatable {
    let version: String
    let riskVersion: String
    let maximumProtectedFrames: Int
    let maximumProtectedLongEdge: Int
    let sharpnessThreshold: Int
    let contrastThreshold: Int

    var isSupported: Bool {
        version == "critical-frame-protection-v1" && riskVersion == "gray-quality-risk-v1" &&
        maximumProtectedFrames == 8 && maximumProtectedLongEdge == 1920 && sharpnessThreshold == 16 && contrastThreshold == 20
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CriticalProtectionKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["version", "riskVersion", "maximumProtectedFrames", "maximumProtectedLongEdge", "sharpnessThreshold", "contrastThreshold"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid critical frame protection capability fields"))
        }
        version = try fields.decode(String.self, forKey: CriticalProtectionKey(stringValue: "version")!)
        riskVersion = try fields.decode(String.self, forKey: CriticalProtectionKey(stringValue: "riskVersion")!)
        maximumProtectedFrames = try fields.decode(Int.self, forKey: CriticalProtectionKey(stringValue: "maximumProtectedFrames")!)
        maximumProtectedLongEdge = try fields.decode(Int.self, forKey: CriticalProtectionKey(stringValue: "maximumProtectedLongEdge")!)
        sharpnessThreshold = try fields.decode(Int.self, forKey: CriticalProtectionKey(stringValue: "sharpnessThreshold")!)
        contrastThreshold = try fields.decode(Int.self, forKey: CriticalProtectionKey(stringValue: "contrastThreshold")!)
        guard isSupported else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported critical frame protection capability"))
        }
    }
}

struct AreaTargetCriticalFrameProtection: Codable, Equatable {
    let version: String
    let riskVersion: String
    let protectedIndices: [Int]
    let candidateFrameCount: Int

    func isValid(sourceFrameCount: Int) -> Bool {
        version == "critical-frame-protection-v1" && riskVersion == "gray-quality-risk-v1" &&
        protectedIndices.count <= 8 && protectedIndices.allSatisfy { $0 >= 0 && $0 < sourceFrameCount } &&
        zip(protectedIndices, protectedIndices.dropFirst()).allSatisfy { $0 < $1 } &&
        candidateFrameCount >= protectedIndices.count && candidateFrameCount <= sourceFrameCount
    }

    private enum CodingKeys: String, CodingKey { case version, riskVersion, protectedIndices, candidateFrameCount }
}

extension AreaTargetCriticalFrameProtection {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CriticalProtectionKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["version", "riskVersion", "protectedIndices", "candidateFrameCount"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid critical frame protection record fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        riskVersion = try values.decode(String.self, forKey: .riskVersion)
        protectedIndices = try values.decode([Int].self, forKey: .protectedIndices)
        candidateFrameCount = try values.decode(Int.self, forKey: .candidateFrameCount)
        guard isValid(sourceFrameCount: 10_000) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid critical frame protection record"))
        }
    }
}

struct AreaTargetProcessingRequirements: Codable, Equatable {
    struct Profile: Codable, Equatable {
        let maxFrames: Int
        let maximumLongEdge: Int
        let maximumTotalPixels: Int64
        var minimumLongEdge: Int? = nil
    }
    struct Safety: Codable, Equatable {
        let maximumRequestBytes: Int64
        let maximumExpandedBytes: Int64
        let maximumArchiveEntries: Int
        let maximumSourceFrameCount: Int
        let maximumImagePixels: Int64
        let maximumImageDimension: Int
        let maximumMetadataBytes: Int64
    }
    let schemaVersion: Int
    let policy: String
    let policyVersion: Int
    let profiles: [String: Profile]
    let safety: Safety
    var capacityTier: Int? = nil
    var criticalFrameProtection: AreaTargetCriticalFrameProtectionCapability? = nil
    private enum CodingKeys: String, CodingKey { case schemaVersion, policy, policyVersion, profiles, safety, capacityTier, criticalFrameProtection }

    func preparationPolicy(for profile: String) -> Profile? {
        guard schemaVersion == 1, ["fast", "quality"].contains(profile), let value = profiles[profile],
              safety.maximumRequestBytes == AreaTargetFileSafety.maximumZIPBytes,
              safety.maximumExpandedBytes == AreaTargetFileSafety.maximumExpandedBytes,
              safety.maximumArchiveEntries == AreaTargetFileSafety.maximumEntries,
              safety.maximumSourceFrameCount == 10_000, safety.maximumImagePixels == 32_000_000,
              safety.maximumImageDimension == 8192,
              safety.maximumMetadataBytes == AreaTargetFileSafety.maximumMetadataBytes else { return nil }
        if policy == "mobile-scan-preparation-v1", policyVersion == 1, criticalFrameProtection == nil,
           (2...80).contains(value.maxFrames), (1...1600).contains(value.maximumLongEdge),
           value.maximumTotalPixels > 0, value.maximumTotalPixels <= 200_000_000 { return value }
        if policy == "mobile-scan-preparation-v2", policyVersion == 2, criticalFrameProtection?.isSupported != false, let capacityTier,
           [100, 500].contains(capacityTier), value.maxFrames == capacityTier,
           value.maximumLongEdge == 1600, value.minimumLongEdge == 1024,
           value.maximumTotalPixels == (capacityTier == 100 ? 200_000_000 : 600_000_000) { return value }
        return nil
    }
}

extension AreaTargetProcessingRequirements {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        policy = try values.decode(String.self, forKey: .policy)
        policyVersion = try values.decode(Int.self, forKey: .policyVersion)
        profiles = try values.decode([String: Profile].self, forKey: .profiles)
        safety = try values.decode(Safety.self, forKey: .safety)
        capacityTier = try values.decodeIfPresent(Int.self, forKey: .capacityTier)
        criticalFrameProtection = values.contains(.criticalFrameProtection) ? try values.decode(AreaTargetCriticalFrameProtectionCapability.self, forKey: .criticalFrameProtection) : nil
    }
}

struct AreaTargetClientPreparation: Codable, Equatable {
    let schemaVersion: Int
    let policy: String
    let policyVersion: Int
    let profile: String
    let preparedBy: String
    let originalFrameCount: Int
    let selectedFrameCount: Int
    let selectedIndices: [Int]
    let processedPixelCount: Int64
    let resizedFrameCount: Int
    let maximumOutputLongEdge: Int
    let scaleDigest: String
    var receivedFrameCount: Int? = nil
    var capacityTier: Int? = nil
    var selectionVersion: String? = nil
    var selectionDigest: String? = nil
    var criticalFrameProtection: AreaTargetCriticalFrameProtection? = nil
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, policy, policyVersion, profile, preparedBy, originalFrameCount, selectedFrameCount, selectedIndices
        case processedPixelCount, resizedFrameCount, maximumOutputLongEdge, scaleDigest, receivedFrameCount, capacityTier, selectionVersion, selectionDigest, criticalFrameProtection
    }

    var identityConfiguration: String {
        let original = "preparation_schema=\(schemaVersion);policy=\(policy);policy_version=\(policyVersion);profile=\(profile);prepared_by=\(preparedBy);original_frames=\(originalFrameCount);selected_frames=\(selectedFrameCount);scale_sha256=\(scaleDigest)"
        guard policy == "mobile-scan-preparation-v2" else { return original }
        let v2 = original + ";capacity_tier=\(capacityTier.map(String.init) ?? "unrecorded");selection_sha256=\(selectionDigest ?? "unrecorded")"
        guard let protection = criticalFrameProtection else { return v2 }
        return v2 + ";critical_frame_protection=\(protection.version);critical_frame_risk=\(protection.riskVersion);protected_indices=\(protection.protectedIndices.map(String.init).joined(separator: ","));candidate_frames=\(protection.candidateFrameCount)"
    }

    static func uploadSelectionDigest(capacityTier: Int, indices: [Int]) throws -> String {
        let record: [String: Any] = ["capacityTier": capacityTier, "policy": "mobile-scan-preparation-v2",
            "selectedIndices": indices, "selectionVersion": "upload-all-v2"]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension AreaTargetClientPreparation {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        policy = try values.decode(String.self, forKey: .policy)
        policyVersion = try values.decode(Int.self, forKey: .policyVersion)
        profile = try values.decode(String.self, forKey: .profile)
        preparedBy = try values.decode(String.self, forKey: .preparedBy)
        originalFrameCount = try values.decode(Int.self, forKey: .originalFrameCount)
        selectedFrameCount = try values.decode(Int.self, forKey: .selectedFrameCount)
        selectedIndices = try values.decode([Int].self, forKey: .selectedIndices)
        processedPixelCount = try values.decode(Int64.self, forKey: .processedPixelCount)
        resizedFrameCount = try values.decode(Int.self, forKey: .resizedFrameCount)
        maximumOutputLongEdge = try values.decode(Int.self, forKey: .maximumOutputLongEdge)
        scaleDigest = try values.decode(String.self, forKey: .scaleDigest)
        receivedFrameCount = try values.decodeIfPresent(Int.self, forKey: .receivedFrameCount)
        capacityTier = try values.decodeIfPresent(Int.self, forKey: .capacityTier)
        selectionVersion = try values.decodeIfPresent(String.self, forKey: .selectionVersion)
        selectionDigest = try values.decodeIfPresent(String.self, forKey: .selectionDigest)
        criticalFrameProtection = values.contains(.criticalFrameProtection) ? try values.decode(AreaTargetCriticalFrameProtection.self, forKey: .criticalFrameProtection) : nil
        if let protection = criticalFrameProtection {
            guard policy == "mobile-scan-preparation-v2", policyVersion == 2, (1...10_000).contains(originalFrameCount),
                  protection.isValid(sourceFrameCount: originalFrameCount) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Critical frame protection does not match the source contract"))
            }
        }
    }
}

enum AreaTargetAPIError: Error, LocalizedError, Equatable {
    case authenticationRequired
    case invalidCredentials
    case credentialStorage
    case invalidRequest(String)
    case transport(String)
    case invalidResponse
    case server(statusCode: Int, problem: AreaTargetAPIProblem, retryAfter: TimeInterval?)
    case invalidResult(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "服务登录已失效，请重新登录。"
        case .invalidCredentials: return "请输入服务用户名和密码。"
        case .credentialStorage: return "无法访问本机登录凭据，请解锁设备后重试。"
        case .invalidRequest: return "上传任务信息无效，请重新创建任务。"
        case .transport: return "网络连接中断，请查询云端状态后重试。"
        case .invalidResponse: return "云端返回的信息无法验证，请稍后查询状态。"
        case .invalidResult: return "云端资产未通过完整性校验，请重新下载。"
        case .cancelled: return "已取消云端请求。"
        case .server(let status, let problem, _):
            if problem.code == "authentication_required" { return "服务登录已失效，请重新登录。" }
            if problem.code == "invalid_credentials" { return "用户名或密码不正确，请重试。" }
            if problem.code == "login_rate_limited" { return "登录尝试过多，请稍后重试。" }
            if problem.code == "auth_not_configured" { return "服务登录尚未配置，请联系管理员。" }
            switch status {
            case 400: return "扫描数据或处理参数无效，请检查后重试。"
            case 401: return "任务凭据无效，请重新创建上传任务。"
            case 404: return "没有找到该云端任务。"
            case 409: return "云端任务暂时无法执行该操作，请查询状态。"
            case 410: return "云端资产已过期，请重新上传扫描。"
            case 413: return "扫描包超过云端大小限制。"
            case 429: return "云端队列已满，请稍后重试。"
            default: return "云端服务暂时不可用，请稍后重试。"
            }
        }
    }
}

protocol AreaTargetAPI {
    var requiresServiceAuthentication: Bool { get }
    func savedServiceSession() throws -> AreaTargetServiceSession?
    func signIn(username: String, password: String) async throws -> AreaTargetServiceSession
    func validateServiceSession() async throws -> AreaTargetServiceSession?
    func signOut() async throws
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements
    func fetchProcessingRequirements(policy: String) async throws -> AreaTargetProcessingRequirements
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob
    func status(jobID: String, token: String) async throws -> AreaTargetRemoteJob
    func download(jobID: String, token: String, result: AreaTargetResult,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension AreaTargetAPI {
    var requiresServiceAuthentication: Bool { false }
    func savedServiceSession() throws -> AreaTargetServiceSession? { nil }
    func signIn(username: String, password: String) async throws -> AreaTargetServiceSession { throw AreaTargetAPIError.invalidResponse }
    func validateServiceSession() async throws -> AreaTargetServiceSession? { try savedServiceSession() }
    func signOut() async throws { }
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements { throw AreaTargetAPIError.invalidResponse }
    func fetchProcessingRequirements(policy: String) async throws -> AreaTargetProcessingRequirements {
        try await fetchProcessingRequirements()
    }
}

/// Every client is bound to one fixed origin. The delegate refuses redirects and keeps transfers on disk.
final class AreaTargetAPIClient: AreaTargetAPI {
    static let baseURL = AreaTargetServerOrigin.current.baseURL
    let origin: AreaTargetServerOrigin
    private let delegate: AreaTargetTransferDelegate
    private let session: URLSession
    private let sessionStore: AreaTargetServiceSessionStoring
    var requiresServiceAuthentication: Bool { true }

    init(origin: AreaTargetServerOrigin = .current, configuration: URLSessionConfiguration = .default,
         sessionStore: AreaTargetServiceSessionStoring = AreaTargetServiceKeychainStore()) {
        self.origin = origin
        self.sessionStore = sessionStore
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7200
        delegate = AreaTargetTransferDelegate(origin: origin)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func savedServiceSession() throws -> AreaTargetServiceSession? {
        guard let saved = try sessionStore.load(origin: origin) else { return nil }
        guard saved.isUsable else { try sessionStore.remove(origin: origin); return nil }
        return saved
    }

    func signIn(username: String, password: String) async throws -> AreaTargetServiceSession {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username.count <= 128, !password.isEmpty, password.count <= 256 else {
            throw AreaTargetAPIError.invalidCredentials
        }
        var request = authRequest("login", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        guard (request.httpBody?.count ?? 0) <= 8192 else { throw AreaTargetAPIError.invalidCredentials }
        let transfer = try await perform(request: request, authenticate: false)
        let saved = try Self.decodeServiceSession(Self.responseData(transfer, accepted: [200]))
        try sessionStore.save(saved, origin: origin)
        return saved
    }

    func validateServiceSession() async throws -> AreaTargetServiceSession? {
        guard let saved = try savedServiceSession() else { return nil }
        let transfer = try await perform(request: authRequest("session", method: "GET"))
        let validated = try Self.decodeServiceSession(Self.responseData(transfer, accepted: [200]), token: saved.token)
        try sessionStore.save(validated, origin: origin)
        return validated
    }

    func signOut() async throws {
        let saved = try? savedServiceSession()
        // Local sign-out takes effect even if revocation cannot reach the server.
        // A failed read must still attempt deletion; only successful deletion confirms logout.
        try sessionStore.remove(origin: origin)
        guard let saved else { return }
        var request = authRequest("logout", method: "POST")
        request.setValue(saved.token, forHTTPHeaderField: "X-Area-Target-Session")
        _ = try Self.responseData(try await perform(request: request, authenticate: false), accepted: [200, 204])
    }

    private func authRequest(_ action: String, method: String) -> URLRequest {
        var request = URLRequest(url: origin.baseURL.appendingPathComponent("api/auth/" + action))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decodeServiceSession(_ data: Data, token: String? = nil) throws -> AreaTargetServiceSession {
        struct Response: Decodable {
            let session_token: String?
            let username: String
            let expires_at: String
            let csrf_token: String
        }
        guard data.count <= 16 * 1024, let response = try? JSONDecoder().decode(Response.self, from: data),
              let token = token ?? response.session_token else { throw AreaTargetAPIError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: response.expires_at)
        formatter.formatOptions = [.withInternetDateTime]
        guard response.expires_at.count <= 64, let expiry = fractional ?? formatter.date(from: response.expires_at) else {
            throw AreaTargetAPIError.invalidResponse
        }
        let saved = AreaTargetServiceSession(token: token, username: response.username, expiresAt: expiry, csrfToken: response.csrf_token)
        guard saved.isUsable else { throw AreaTargetAPIError.invalidResponse }
        return saved
    }

    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements {
        try await processingRequirements(policy: nil)
    }

    func fetchProcessingRequirements(policy: String) async throws -> AreaTargetProcessingRequirements {
        guard policy == "mobile-scan-preparation-v2" else { throw AreaTargetAPIError.invalidRequest("policy") }
        return try await processingRequirements(policy: policy)
    }

    private func processingRequirements(policy: String?) async throws -> AreaTargetProcessingRequirements {
        var components = URLComponents(url: origin.baseURL.appendingPathComponent("api/v1/processing-requirements"), resolvingAgainstBaseURL: false)!
        if let policy { components.queryItems = [URLQueryItem(name: "policy", value: policy)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let transfer = try await perform(request: request)
        let data = try Self.responseData(transfer, accepted: [200])
        guard data.count <= 16 * 1024 else { throw AreaTargetAPIError.invalidResponse }
        do {
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AreaTargetAPIError.invalidResponse }
            try AreaTargetCriticalProtectionJSON.validateRequirements(document)
            return try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: data)
        } catch {
            throw AreaTargetAPIError.invalidResponse
        }
    }

    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        try Self.validateIdentity(jobID, token: token)
        guard ["fast", "quality"].contains(profile) else { throw AreaTargetAPIError.invalidRequest("profile") }
        try Task.checkCancellation()
        let boundary = "AreaTarget-" + UUID().uuidString.lowercased()
        let body = try Self.makeMultipartFile(archiveURL: archiveURL, profile: profile, uvUnwrap: uvUnwrap, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = request(jobID: nil, token: token)
        request.httpMethod = "POST"
        request.setValue(jobID, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(try AreaTargetFileSafety.regularFileSize(body)), forHTTPHeaderField: "Content-Length")
        let transfer = try await perform(request: request, uploadFile: body, progress: progress)
        let bytes = try Self.responseData(transfer, accepted: [200, 202])
        let job = try Self.decodeJob(bytes, jobID: jobID)
        guard job.profile == profile, job.uvUnwrap == uvUnwrap else { throw AreaTargetAPIError.invalidResponse }
        return job
    }

    func status(jobID: String, token: String) async throws -> AreaTargetRemoteJob {
        try Self.validateIdentity(jobID, token: token)
        let transfer = try await perform(request: request(jobID: jobID, token: token))
        return try Self.decodeJob(Self.responseData(transfer, accepted: [200]), jobID: jobID)
    }

    func download(jobID: String, token: String, result: AreaTargetResult,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Self.validateIdentity(jobID, token: token)
        try Self.validateResult(result, jobID: jobID)
        var request = request(jobID: jobID, token: token)
        request.url = origin.baseURL.appendingPathComponent("api/v1/jobs/\(jobID)/result")
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let transfer = try await perform(request: request, downloadSize: result.sizeBytes, progress: progress)
        guard let file = transfer.file else { throw AreaTargetAPIError.invalidResponse }
        do {
            guard transfer.response.statusCode == 200 else {
                throw try Self.serverError(transfer.response, data: AreaTargetFileSafety.smallData(file, maximum: 65_536))
            }
            try Task.checkCancellation()
            let actual = try AreaTargetFileSafety.digest(file, maximum: AreaTargetFileSafety.maximumZIPBytes, isCancelled: { Task.isCancelled })
            guard actual.size == result.sizeBytes, actual.sha256 == result.sha256 else { throw AreaTargetAPIError.invalidResult("digest") }
            try Task.checkCancellation()
            progress(1)
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    static func validateIdentity(_ jobID: String, token: String? = nil) throws {
        guard let uuid = UUID(uuidString: jobID), uuid.uuidString.lowercased() == jobID else { throw AreaTargetAPIError.invalidRequest("job_id") }
        if let token, !AreaTargetFileSafety.isLowerHex64(token) { throw AreaTargetAPIError.invalidRequest("token") }
    }

    static func validateResult(_ result: AreaTargetResult, jobID: String) throws {
        try validateIdentity(jobID)
        guard result.format == "area-target-bundle", result.filename.count <= 255,
              AreaTargetFileSafety.safeRelativePath(result.filename), !result.filename.contains("/"),
              result.filename.lowercased().hasSuffix(".zip"), result.sizeBytes > 0,
              result.sizeBytes <= AreaTargetFileSafety.maximumZIPBytes,
              AreaTargetFileSafety.isLowerHex64(result.sha256),
              result.url == "/api/v1/jobs/\(jobID)/result", result.expiresAt.timeIntervalSince1970.isFinite else {
            throw AreaTargetAPIError.invalidResponse
        }
    }

    /// Builds an upload body in a separate owned file; never reads the scan ZIP into memory.
    static func makeMultipartFile(archiveURL: URL, profile: String, uvUnwrap: Bool, boundary: String) throws -> URL {
        guard ["fast", "quality"].contains(profile), !boundary.isEmpty,
              boundary.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AreaTargetAPIError.invalidRequest("multipart")
        }
        let size = try AreaTargetFileSafety.regularFileSize(archiveURL)
        guard size > 0, size < AreaTargetFileSafety.maximumZIPBytes else { throw AreaTargetAPIError.invalidRequest("archive size") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("area-target-upload-" + UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw AreaTargetAPIError.invalidRequest("temporary file") }
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"profile\"\r\n\r\n\(profile)\r\n")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"uv_unwrap\"\r\n\r\n\(uvUnwrap ? "1" : "0")\r\n")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"scan.zip\"\r\nContent-Type: application/zip\r\n\r\n")
            let input = try FileHandle(forReadingFrom: archiveURL)
            defer { try? input.close() }
            var copied: Int64 = 0
            while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                copied += Int64(bytes.count)
                guard copied <= size else { throw AreaTargetAPIError.invalidRequest("source changed") }
                try handle.write(contentsOf: bytes)
            }
            guard copied == size else { throw AreaTargetAPIError.invalidRequest("source changed") }
            try write("\r\n--\(boundary)--\r\n")
            try handle.synchronize()
            guard try AreaTargetFileSafety.regularFileSize(output) <= AreaTargetFileSafety.maximumZIPBytes else { throw AreaTargetAPIError.invalidRequest("request size") }
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }

    private func request(jobID: String?, token: String) -> URLRequest {
        var request = URLRequest(url: origin.baseURL.appendingPathComponent("api/v1/jobs" + (jobID.map { "/" + $0 } ?? "")))
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(request: URLRequest, uploadFile: URL? = nil, downloadSize: Int64? = nil, authenticate: Bool = true,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AreaTargetTransfer {
        guard let url = request.url, origin.allows(url) else { throw AreaTargetAPIError.invalidRequest("origin") }
        var request = request
        if authenticate {
            guard let saved = try savedServiceSession() else { throw AreaTargetAPIError.authenticationRequired }
            request.setValue(saved.token, forHTTPHeaderField: "X-Area-Target-Session")
        }
        let operation = AreaTargetTransferOperation(progress: progress, expectedSize: downloadSize)
        let transfer: AreaTargetTransfer = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionTask
                if let uploadFile { task = session.uploadTask(with: request, fromFile: uploadFile) }
                else if downloadSize != nil { task = session.downloadTask(with: request) }
                else { task = session.dataTask(with: request) }
                operation.continuation = continuation
                delegate.register(operation, task: task)
                operation.install(task)
                task.resume()
            }
        }, onCancel: { operation.cancel() })
        if transfer.response.statusCode == 401 {
            let errorData = transfer.file.flatMap { try? AreaTargetFileSafety.smallData($0, maximum: 65_536) } ?? transfer.data
            if case .server(_, let problem, _) = Self.serverError(transfer.response, data: errorData),
               problem.code == "authentication_required",
               try sessionStore.load(origin: origin)?.token == request.value(forHTTPHeaderField: "X-Area-Target-Session") {
                try sessionStore.remove(origin: origin)
            }
        }
        return transfer
    }

    private static func decodeJob(_ data: Data, jobID: String) throws -> AreaTargetRemoteJob {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                guard text.count <= 64 else { throw AreaTargetAPIError.invalidResponse }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: text) else { throw AreaTargetAPIError.invalidResponse }
                return date
            }
            let job = try decoder.decode(AreaTargetRemoteJob.self, from: data)
            let stages = ["queued", "extracting", "uv_unwrap", "model_optimization", "feature_extraction", "packaging", "completed", "failed"]
            guard job.jobID == jobID, (0...100).contains(job.progress), stages.contains(job.stage),
                  ["fast", "quality"].contains(job.profile), job.message.utf8.count <= 2048,
                  job.error.map({ validProblem($0) }) ?? true,
                  (job.status != .completed || (job.result != nil && job.progress == 100 && job.stage == "completed")),
                  (job.status != .failed || (job.error != nil && job.stage == "failed")),
                  (job.result == nil || job.status == .completed) else { throw AreaTargetAPIError.invalidResponse }
            if let result = job.result { try validateResult(result, jobID: jobID) }
            return job
        } catch { throw AreaTargetAPIError.invalidResponse }
    }

    private static func responseData(_ transfer: AreaTargetTransfer, accepted: Set<Int>) throws -> Data {
        guard accepted.contains(transfer.response.statusCode) else { throw serverError(transfer.response, data: transfer.data) }
        return transfer.data
    }
    private static func validProblem(_ problem: AreaTargetAPIProblem) -> Bool {
        !problem.code.isEmpty && problem.code.utf8.count <= 128 && problem.message.utf8.count <= 2048 &&
        problem.code.utf8.allSatisfy { (45...57).contains($0) || (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }
    }
    private static func serverError(_ response: HTTPURLResponse, data: Data) -> AreaTargetAPIError {
        struct Envelope: Decodable { let error: AreaTargetAPIProblem }
        struct LegacyEnvelope: Decodable { let error: String; let code: String }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
        let legacy = (try? JSONDecoder().decode(LegacyEnvelope.self, from: data)).map {
            AreaTargetAPIProblem(code: $0.code, message: $0.error, retryable: response.statusCode == 429 || response.statusCode >= 500)
        }
        let problem = decoded.flatMap { validProblem($0.error) ? $0.error : nil } ?? legacy.flatMap { validProblem($0) ? $0 : nil } ?? AreaTargetAPIProblem(code: "http_\(response.statusCode)", message: "服务未完成请求", retryable: response.statusCode == 429 || response.statusCode >= 500)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 && $0 <= 86_400 ? $0 : nil }
        return .server(statusCode: response.statusCode, problem: problem, retryAfter: retryAfter)
    }
}

private struct AreaTargetTransfer {
    let response: HTTPURLResponse
    let data: Data
    let file: URL?
}

private final class AreaTargetTransferOperation: @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let expectedSize: Int64?
    var continuation: CheckedContinuation<AreaTargetTransfer, Error>?
    var data = Data()
    var file: URL?
    var failure: Error?
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    init(progress: @escaping @Sendable (Double) -> Void, expectedSize: Int64?) { self.progress = progress; self.expectedSize = expectedSize }
    func install(_ task: URLSessionTask) { lock.lock(); self.task = task; let cancelled = cancelled; lock.unlock(); if cancelled { task.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}

private final class AreaTargetTransferDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let origin: AreaTargetServerOrigin
    init(origin: AreaTargetServerOrigin) { self.origin = origin; super.init() }
    private let lock = NSLock()
    private var operations: [Int: AreaTargetTransferOperation] = [:]
    func register(_ operation: AreaTargetTransferOperation, task: URLSessionTask) { lock.lock(); operations[task.taskIdentifier] = operation; lock.unlock() }
    private func operation(_ task: URLSessionTask) -> AreaTargetTransferOperation? { lock.lock(); defer { lock.unlock() }; return operations[task.taskIdentifier] }
    private func validResponse(_ response: URLResponse?) -> HTTPURLResponse? {
        guard let response = response as? HTTPURLResponse, let url = response.url,
              origin.allows(url) else { return nil }
        return response
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard validResponse(response) != nil, response.expectedContentLength <= 65_536 else { operation(dataTask)?.failure = AreaTargetAPIError.invalidResponse; completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let operation = operation(dataTask) else { return }
        guard operation.data.count + data.count <= 65_536 else { operation.failure = AreaTargetAPIError.invalidResponse; dataTask.cancel(); return }
        operation.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { operation(task)?.progress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let operation = operation(downloadTask) else { return }
        if totalBytesWritten > AreaTargetFileSafety.maximumZIPBytes { operation.failure = AreaTargetAPIError.invalidResult("size"); downloadTask.cancel(); return }
        if let expected = operation.expectedSize, expected > 0 { operation.progress(min(1, max(0, Double(totalBytesWritten) / Double(expected)))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let operation = operation(downloadTask) else { return }
        do {
            guard validResponse(downloadTask.response) != nil, try AreaTargetFileSafety.regularFileSize(location) <= AreaTargetFileSafety.maximumZIPBytes else { throw AreaTargetAPIError.invalidResponse }
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("area-target-download-" + UUID().uuidString + ".zip")
            try FileManager.default.moveItem(at: location, to: owned)
            operation.file = owned
        } catch { operation.failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let operation = operations.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let operation else { return }
        let failure = operation.failure ?? error.map { ($0 as? URLError)?.code == .cancelled ? AreaTargetAPIError.cancelled : .transport(String(($0 as NSError).code)) }
        if let failure {
            if let file = operation.file { try? FileManager.default.removeItem(at: file) }
            operation.continuation?.resume(throwing: failure)
        } else if let response = validResponse(task.response) {
            operation.continuation?.resume(returning: AreaTargetTransfer(response: response, data: operation.data, file: operation.file))
        } else {
            if let file = operation.file { try? FileManager.default.removeItem(at: file) }
            operation.continuation?.resume(throwing: AreaTargetAPIError.invalidResponse)
        }
    }
}

/// Shared, bounded streaming file operations used by transport and asset persistence.
enum AreaTargetFileSafety {
    static let maximumZIPBytes: Int64 = 512 * 1024 * 1024
    static let maximumExpandedBytes: Int64 = 500 * 1024 * 1024
    static let maximumEntries = 10_000
    static let maximumMetadataBytes: Int64 = 8 * 1024 * 1024
    static func isLowerHex64(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.contains("\0") &&
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func regularFileSize(_ url: URL) throws -> Int64 {
        guard url.isFileURL else { throw AreaTargetAPIError.invalidResult("file URL") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else { throw AreaTargetAPIError.invalidResult("regular file") }
        return Int64(size)
    }
    static func safeFile(_ path: String, in root: URL) throws -> URL {
        guard safeRelativePath(path) else { throw AreaTargetAPIError.invalidResult("path") }
        var current = root.standardizedFileURL
        for part in path.split(separator: "/") {
            current.appendPathComponent(String(part))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AreaTargetAPIError.invalidResult("symlink") }
        }
        _ = try regularFileSize(current)
        return current
    }
    static func smallData(_ url: URL, maximum: Int64 = maximumMetadataBytes) throws -> Data {
        guard try regularFileSize(url) <= maximum else { throw AreaTargetAPIError.invalidResult("metadata size") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(maximum) + 1) ?? Data()
        guard data.count <= maximum else { throw AreaTargetAPIError.invalidResult("metadata size") }
        return data
    }
    static func digest(_ url: URL, maximum: Int64, isCancelled: () -> Bool = { false }) throws -> (size: Int64, sha256: String) {
        let expected = try regularFileSize(url)
        guard expected > 0, expected <= maximum else { throw AreaTargetAPIError.invalidResult("size") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var size: Int64 = 0
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            if isCancelled() { throw AreaTargetAPIError.cancelled }
            size += Int64(data.count)
            guard size <= maximum else { throw AreaTargetAPIError.invalidResult("size") }
            hasher.update(data: data)
        }
        guard size == expected else { throw AreaTargetAPIError.invalidResult("source changed") }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
