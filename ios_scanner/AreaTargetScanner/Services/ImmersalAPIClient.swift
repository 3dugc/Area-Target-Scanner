import Foundation

struct ImmersalCredential: Codable, Equatable {
    let email: String
    let userID: Int
    let token: String
}

struct ImmersalAccountStatus: Decodable {
    let userID: Int
    let imageCount: Int
    let imageMax: Int
    enum CodingKeys: String, CodingKey { case userID = "userId", imageCount, imageMax }
}

struct ImmersalConstruction: Decodable {
    let id: Int
    let size: Int
}

struct ImmersalRemoteJob: Decodable {
    let id: Int
    let size: Int
    let name: String
    let status: String
}

enum ImmersalAPIError: Error, LocalizedError, Equatable {
    case authentication
    case rejected(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authentication: return "登录信息已失效，请重新输入邮箱和密码。"
        case .http(let status): return "Immersal 服务暂时不可用（HTTP \(status)）。"
        case .invalidResponse: return "Immersal 返回了无法确认的结果，请查询云端状态。"
        case .rejected(let code):
            switch code {
            case "login", "password": return "邮箱或密码不正确，请重试。"
            case "image limit": return "账号图片容量不足。"
            case "image format", "blob": return "服务器未接受图片格式。"
            case "name": return "地图名称仅支持英文字母和数字。"
            case "capture count": return "云端工作区没有可用于建图的图片。"
            case "limit": return "服务未能确认建图任务已写入，请查询云端状态。"
            default: return "Immersal 未完成请求，请稍后检查云端状态。"
            }
        }
    }

    /// Only documented validation/auth failures are safe to retry without reconciliation.
    var definitelyRejected: Bool {
        switch self {
        case .authentication: return true
        case .rejected(let code): return ["login", "password", "image limit", "image format", "blob", "name", "capture count"].contains(code)
        default: return false
        }
    }
}

protocol ImmersalAPI {
    func login(email: String, password: String) async throws -> ImmersalCredential
    func status(token: String) async throws -> ImmersalAccountStatus
    func capture(frame: ImmersalUploadFrame, token: String) async throws
    func clear(token: String) async throws
    func construct(name: String, token: String) async throws -> ImmersalConstruction
    func jobs(token: String) async throws -> [ImmersalRemoteJob]
}

/// Credentials are sent only to the fixed official HTTPS host, never in URLs or logs.
final class ImmersalAPIClient: ImmersalAPI {
    private let session: URLSession
    private let redirectGuard: ImmersalRedirectGuard
    private let baseURL = URL(string: "https://api.immersal.com")!

    init(session: URLSession? = nil) {
        let guardDelegate = ImmersalRedirectGuard()
        redirectGuard = guardDelegate
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 180
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    func login(email: String, password: String) async throws -> ImmersalCredential {
        struct Login: Decodable { let userId: Int; let token: String }
        let data = try await request("login", json: ["login": email, "password": password])
        let response: Login = try decode(data)
        guard response.userId >= 0, !response.token.isEmpty else { throw ImmersalAPIError.invalidResponse }
        return ImmersalCredential(email: email, userID: response.userId, token: response.token)
    }

    func status(token: String) async throws -> ImmersalAccountStatus {
        let result: ImmersalAccountStatus = try decode(await request("status", json: ["token": token]))
        guard result.userID >= 0, result.imageCount >= 0, result.imageMax >= 0 else { throw ImmersalAPIError.invalidResponse }
        return result
    }

    func capture(frame: ImmersalUploadFrame, token: String) async throws {
        guard var metadata = try JSONSerialization.jsonObject(with: frame.metadata) as? [String: Any], !frame.png.isEmpty else {
            throw ImmersalAPIError.invalidResponse
        }
        metadata.removeValue(forKey: "imagePath")
        metadata["token"] = token
        var body = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        body.append(0)
        body.append(frame.png)
        _ = try await send("capture", body: body, contentType: "application/octet-stream")
    }

    func clear(token: String) async throws {
        _ = try await request("clear", json: ["token": token, "anchor": true])
    }

    func construct(name: String, token: String) async throws -> ImmersalConstruction {
        let result: ImmersalConstruction = try decode(await request("construct", json: ["token": token, "name": name, "preservePoses": true]))
        guard result.id > 0, result.size > 0 else { throw ImmersalAPIError.invalidResponse }
        return result
    }

    func jobs(token: String) async throws -> [ImmersalRemoteJob] {
        struct Response: Decodable { let jobs: [ImmersalRemoteJob] }
        let result: Response = try decode(await request("list", json: ["token": token]))
        return result.jobs
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ImmersalAPIError.invalidResponse }
    }

    private func request(_ endpoint: String, json: [String: Any]) async throws -> Data {
        try await send(endpoint, body: JSONSerialization.data(withJSONObject: json), contentType: "application/json")
    }

    private func send(_ endpoint: String, body: Data, contentType: String) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == baseURL.host,
              http.url?.scheme == "https" else { throw ImmersalAPIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ImmersalAPIError.authentication }
        guard (200..<300).contains(http.statusCode) else { throw ImmersalAPIError.http(http.statusCode) }
        struct Envelope: Decodable { let error: String }
        let envelope: Envelope = try decode(data)
        if envelope.error == "auth" { throw ImmersalAPIError.authentication }
        guard envelope.error == "none" else { throw ImmersalAPIError.rejected(envelope.error) }
        return data
    }
}

private final class ImmersalRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
