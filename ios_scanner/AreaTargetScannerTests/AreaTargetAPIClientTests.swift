import XCTest
import CryptoKit
@testable import AreaTargetScanner

final class AreaTargetAPIClientTests: XCTestCase {
    let jobID = "5c372062-9130-40ed-9efe-5ef336c7e332"
    let token = String(repeating: "a", count: 64)

    func testMapCLAHECapabilityRoundTripPreservesExplicitBoolean() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: requirementsJSON()) as? [String: Any])
        object["map_clahe_supported"] = true
        let requirements = try JSONDecoder().decode(AreaTargetProcessingRequirements.self,
            from: JSONSerialization.data(withJSONObject: object))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(requirements)) as? [String: Any])
        XCTAssertEqual(encoded["map_clahe_supported"] as? Bool, true,
            "The top-level capability must survive decoding and encoding")
    }

    func testServiceAuthenticationFailurePromptsSignInWithoutMentioningTaskCredentials() {
        let error = AreaTargetAPIError.server(statusCode: 401,
            problem: .init(code: "authentication_required", message: "Please sign in", retryable: false), retryAfter: nil)
        XCTAssertEqual(error.localizedDescription, "服务登录已失效，请重新登录。")
    }

    func testLoginPersistsOpaqueSessionAndKeepsPasswordOutOfStoredCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let store = AreaServiceTestSessions()
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/auth/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Area-Target-Session"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.bodyData(request)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(value, ["username": "scanner", "password": " private password "])
            return (200, self.serviceSessionJSON())
        }
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: store)
        let session = try await client.signIn(username: " scanner ", password: " private password ")
        XCTAssertEqual(session.username, "scanner")
        XCTAssertEqual(session.token, String(repeating: "b", count: 64))
        XCTAssertEqual(try store.load(origin: .current), session)
        let storedBytes = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("password"))
        XCTAssertNil(try store.load(origin: .legacy))

        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), session.token)
            return (200, self.jobJSON())
        }
        _ = try await AreaTargetAPIClient(configuration: configuration, sessionStore: store).status(jobID: jobID, token: token)
    }

    func testBusinessRequestWithoutServiceSessionNeverReachesTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { _ in XCTFail("Signed out request reached transport"); return (200, self.jobJSON()) }
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: AreaServiceTestSessions())
        do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted signed out request") }
        catch { XCTAssertEqual(error as? AreaTargetAPIError, .authenticationRequired) }
    }

    func testLoginCredentialLengthBoundsMatchServerAndCountCharacters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: AreaServiceTestSessions())
        var calls = 0
        AreaTargetTestURLProtocol.handler = { _ in calls += 1; return (200, self.serviceSessionJSON()) }
        for (username, password) in [(String(repeating: "u", count: 129), "password"),
                                     ("scanner", String(repeating: "p", count: 257))] {
            do { _ = try await client.signIn(username: username, password: password); XCTFail("accepted oversized credential") }
            catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidCredentials) }
        }
        XCTAssertEqual(calls, 0)
        _ = try await client.signIn(username: String(repeating: "用", count: 128), password: String(repeating: "p", count: 256))
        XCTAssertEqual(calls, 1)
    }

    func testSessionValidationUsesSavedTokenAndLogoutClearsItEvenWhenServerUnavailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let store = AreaServiceTestSessions.authenticated()
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: store)
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/session")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, self.serviceSessionJSON(includeToken: false))
        }
        let validated = try await client.validateServiceSession()
        XCTAssertEqual(validated?.token, String(repeating: "b", count: 64))
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            return (503, Data(#"{"error":"Service unavailable","code":"unavailable"}"#.utf8))
        }
        do { try await client.signOut(); XCTFail("accepted unavailable logout") } catch { }
        XCTAssertNil(try store.load(origin: .current))
        XCTAssertNotNil(try store.load(origin: .legacy), "Logout must clear only this fixed origin")
    }

    func testSignOutAttemptsLocalRemovalWhenKeychainReadFails() async throws {
        let store = AreaServiceTestSessions.authenticated()
        store.failLoads = true
        let client = AreaTargetAPIClient(sessionStore: store)
        do { try await client.signOut() }
        catch { XCTFail("A Keychain read failure must not prevent confirmed local removal") }
        XCTAssertEqual(store.removeAttempts, 1)
        store.failLoads = false
        XCTAssertNil(try store.load(origin: .current))
        XCTAssertNotNil(try store.load(origin: .legacy))
    }

    func testSignOutReportsFailedKeychainRemovalAndPreservesSession() async throws {
        let store = AreaServiceTestSessions.authenticated()
        store.failRemovals = true
        let client = AreaTargetAPIClient(sessionStore: store)
        do { try await client.signOut(); XCTFail("accepted failed session removal") }
        catch { XCTAssertEqual(error as? AreaTargetAPIError, .credentialStorage) }
        XCTAssertEqual(store.removeAttempts, 1)
        XCTAssertNotNil(try store.load(origin: .current))
    }

    func testRejectedServiceSessionClearsSavedSessionButKeepsTaskTokenErrorSeparate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let store = AreaServiceTestSessions.authenticated()
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: store)
        AreaTargetTestURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"code":"authentication_required","message":"Please sign in","retryable":false}}"#.utf8))
        }
        do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted rejected session") }
        catch { XCTAssertEqual(error.localizedDescription, "服务登录已失效，请重新登录。") }
        XCTAssertNil(try store.load(origin: .current))

        let taskFailure = AreaTargetAPIError.server(statusCode: 401,
            problem: .init(code: "invalid_token", message: "Invalid task token", retryable: false), retryAfter: nil)
        XCTAssertEqual(taskFailure.localizedDescription, "任务凭据无效，请重新创建上传任务。")
    }

    func testRejectedServiceSessionDuringDownloadClearsSavedSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let store = AreaServiceTestSessions.authenticated()
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: store)
        let result = AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: 4,
            sha256: String(repeating: "a", count: 64), url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(3600))
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            return (401, Data(#"{"error":{"code":"authentication_required","message":"Please sign in","retryable":false}}"#.utf8))
        }
        do { _ = try await client.download(jobID: jobID, token: token, result: result, progress: { _ in }); XCTFail("accepted rejected download session") }
        catch { XCTAssertEqual(error.localizedDescription, "服务登录已失效，请重新登录。") }
        XCTAssertNil(try store.load(origin: .current))
    }

    func testServiceKeychainSessionRoundTripIsScopedToFixedOrigin() throws {
        let store = AreaTargetServiceKeychainStore(service: "com.areatarget.scanner.service-test.\(UUID().uuidString)")
        defer { for origin in AreaTargetServerOrigin.allCases { try? store.remove(origin: origin) } }
        let session = AreaTargetServiceSession(token: String(repeating: "b", count: 64), username: "scanner",
            expiresAt: Date().addingTimeInterval(3600), csrfToken: String(repeating: "c", count: 64))
        try store.save(session, origin: .current)
        XCTAssertEqual(try store.load(origin: .current), session)
        XCTAssertNil(try store.load(origin: .legacy))
        try store.remove(origin: .current)
        XCTAssertNil(try store.load(origin: .current))
    }

    func testLoginFailureAndRateLimitUseUsefulSanitizedMessages() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: AreaServiceTestSessions())
        for (status, code, message) in [(401, "invalid_credentials", "用户名或密码不正确，请重试。"),
                                       (429, "login_rate_limited", "登录尝试过多，请稍后重试。"),
                                       (503, "auth_not_configured", "服务登录尚未配置，请联系管理员。")] {
            AreaTargetTestURLProtocol.handler = { _ in
                (status, try JSONSerialization.data(withJSONObject: ["error": "secret server details", "code": code]))
            }
            do { _ = try await client.signIn(username: "scanner", password: "password"); XCTFail("accepted login failure") }
            catch { XCTAssertEqual(error.localizedDescription, message) }
        }
    }

    func testExpiredOrMalformedLoginSessionIsNotSaved() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let store = AreaServiceTestSessions()
        let client = AreaTargetAPIClient(configuration: configuration, sessionStore: store)
        for bytes in [Data(String(decoding: serviceSessionJSON(), as: UTF8.self).replacingOccurrences(of: String(repeating: "b", count: 64), with: "secret").utf8),
                      serviceSessionJSON(expiry: Date().addingTimeInterval(-60))] {
            AreaTargetTestURLProtocol.handler = { _ in (200, bytes) }
            do { _ = try await client.signIn(username: "scanner", password: "password"); XCTFail("accepted invalid session") }
            catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
            XCTAssertNil(try? store.load(origin: .current))
        }
    }

    private func serviceSessionJSON(includeToken: Bool = true, expiry: Date = Date().addingTimeInterval(3600)) -> Data {
        var object: [String: Any] = ["username": "scanner", "expires_at": ISO8601DateFormatter().string(from: expiry),
                                   "csrf_token": String(repeating: "c", count: 64)]
        if includeToken { object["session_token"] = String(repeating: "b", count: 64) }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? AreaTargetAPIError.invalidResponse }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func testStatusUsesFixedHTTPSBearerAndSnakeCaseDates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/v1/jobs/\(self.jobID)")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            XCTAssertNil(request.url?.query)
            return (200, self.jobJSON())
        }
        let job = try await authenticatedClient(configuration: configuration).status(jobID: jobID, token: token)
        XCTAssertEqual(job.jobID, jobID)
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.progress, 0)
        XCTAssertEqual(job.createdAt.timeIntervalSince1970, 1_791_072_000.123, accuracy: 0.001)
    }

    func testInvalidIdentityAndTokenNeverReachTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { _ in XCTFail("invalid identity reached network"); return (200, self.jobJSON()) }
        let client = authenticatedClient(configuration: configuration)
        for (id, secret) in [(jobID.uppercased(), token), ("../outside", token), (jobID, "secret"), (jobID, token.uppercased())] {
            do { _ = try await client.status(jobID: id, token: secret); XCTFail("accepted invalid input") }
            catch { guard case .invalidRequest = error as? AreaTargetAPIError else { return XCTFail("unexpected \(error)") } }
        }
    }

    func testMalformedAndUnknownJobsAreRejected() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = authenticatedClient(configuration: configuration)
        for replacement in [("\"progress\":0", "\"progress\":101"), ("\"status\":\"queued\"", "\"status\":\"unknown\""), ("\"stage\":\"queued\"", "\"stage\":\"https://leak\""), (jobID, UUID().uuidString.lowercased()), ("2026-10-04T00:00:00.123Z", "invalid")] {
            let body = Data(String(decoding: jobJSON(), as: UTF8.self).replacingOccurrences(of: replacement.0, with: replacement.1).utf8)
            AreaTargetTestURLProtocol.handler = { _ in (200, body) }
            do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted malformed job") }
            catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
        }
    }

    func testStructuredFailuresKeepRetryAfterButHideUntrustedServerMessage() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.headers = ["Retry-After": "10"]
        defer { AreaTargetTestURLProtocol.headers = [:] }
        AreaTargetTestURLProtocol.handler = { _ in (429, Data(#"{"error":{"code":"queue_full","message":"secret /private/server","retryable":true}}"#.utf8)) }
        do { _ = try await authenticatedClient(configuration: configuration).status(jobID: jobID, token: token); XCTFail("accepted failure") }
        catch {
            guard case let .server(status, problem, retryAfter) = error as? AreaTargetAPIError else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(problem.code, "queue_full")
            XCTAssertTrue(problem.retryable)
            XCTAssertEqual(retryAfter, 10)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testMapCLAHERequirementsMissingMeansUnsupportedAndOnlyBooleansAreAccepted() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: requirementsJSON()) as? [String: Any])
        let historical = try JSONDecoder().decode(AreaTargetProcessingRequirements.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(historical.mapCLAHESupported)
        object["map_clahe_supported"] = true
        XCTAssertTrue(try JSONDecoder().decode(AreaTargetProcessingRequirements.self,
            from: JSONSerialization.data(withJSONObject: object)).mapCLAHESupported)
        for invalid in [NSNull(), 0, 1, "true"] as [Any] {
            object["map_clahe_supported"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AreaTargetProcessingRequirements.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testMapCLAHERemoteMissingMeansDisabledAndOnlyBooleansAreAccepted() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: jobJSON()) as? [String: Any])
        object["created_at"] = "2026-10-04T00:00:00Z"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertFalse(try decoder.decode(AreaTargetRemoteJob.self, from: JSONSerialization.data(withJSONObject: object)).mapCLAHE)
        object["map_clahe"] = true
        XCTAssertTrue(try decoder.decode(AreaTargetRemoteJob.self, from: JSONSerialization.data(withJSONObject: object)).mapCLAHE)
        for invalid in [NSNull(), 0, 1, "true"] as [Any] {
            object["map_clahe"] = invalid
            XCTAssertThrowsError(try decoder.decode(AreaTargetRemoteJob.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testEnabledMapCLAHEMultipartSendsOnlyOneLiteralOneField() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("original archive marker".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let body = try AreaTargetAPIClient.makeMultipartFile(archiveURL: input, profile: "quality", uvUnwrap: true,
            mapCLAHE: true, boundary: "map-clahe-fixture")
        defer { try? FileManager.default.removeItem(at: body) }
        let text = try String(contentsOf: body, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "name=\"map_clahe\"").count - 1, 1)
        XCTAssertTrue(text.contains("name=\"map_clahe\"\r\n\r\n1\r\n"))
        XCTAssertTrue(text.contains("original archive marker"))
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "original archive marker")
    }

    func testEnabledMapCLAHERejectsServerEchoMissingOrDisabled() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("scan bytes".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        for flag in [nil, false, true] as [Bool?] {
            AreaTargetTestURLProtocol.handler = { _ in
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.jobJSON()) as? [String: Any])
                if let flag { object["map_clahe"] = flag }
                return (202, try JSONSerialization.data(withJSONObject: object))
            }
            do {
                let remote = try await authenticatedClient(configuration: configuration).submit(archiveURL: input,
                    jobID: jobID, token: token, profile: "fast", uvUnwrap: true, mapCLAHE: true, progress: { _ in })
                XCTAssertEqual(flag, true)
                XCTAssertTrue(remote.mapCLAHE)
            } catch {
                XCTAssertNotEqual(flag, true)
                XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse)
            }
        }
    }

    func testExplicitDisabledMapCLAHEKeepsOriginalMultipartBytes() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("original archive marker".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let original = try AreaTargetAPIClient.makeMultipartFile(archiveURL: input, profile: "fast", uvUnwrap: true,
            boundary: "unchanged-off-body")
        let disabled = try AreaTargetAPIClient.makeMultipartFile(archiveURL: input, profile: "fast", uvUnwrap: true,
            mapCLAHE: false, boundary: "unchanged-off-body")
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: disabled) }
        XCTAssertEqual(try Data(contentsOf: disabled), try Data(contentsOf: original))
        XCTAssertFalse(try String(contentsOf: disabled, encoding: .utf8).contains("name=\"map_clahe\""))
    }

    func testDisabledMapCLAHERejectsUnexpectedEnabledServerEcho() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("scan bytes".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { _ in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.jobJSON()) as? [String: Any])
            object["map_clahe"] = true
            return (202, try JSONSerialization.data(withJSONObject: object))
        }
        do {
            _ = try await authenticatedClient(configuration: configuration).submit(archiveURL: input,
                jobID: jobID, token: token, profile: "fast", uvUnwrap: true, mapCLAHE: false, progress: { _ in })
            XCTFail("Accepted server option different from the frozen disabled choice")
        } catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
    }

    func testMultipartIsFreshFileBackedAndUsesLiteralFields() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("archive marker".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let body = try AreaTargetAPIClient.makeMultipartFile(archiveURL: input, profile: "quality", uvUnwrap: true, boundary: "fixture-boundary")
        defer { try? FileManager.default.removeItem(at: body) }
        XCTAssertNotEqual(input, body)
        let text = try String(contentsOf: body, encoding: .utf8)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"scan.zip\"\r\nContent-Type: application/zip"))
        XCTAssertTrue(text.contains("name=\"profile\"\r\n\r\nquality\r\n"))
        XCTAssertTrue(text.contains("name=\"uv_unwrap\"\r\n\r\n1\r\n"))
        XCTAssertFalse(text.contains("name=\"map_clahe\""), "Default off must omit the extension for older services")
        XCTAssertTrue(text.contains("archive marker"))
        XCTAssertTrue(text.hasSuffix("--fixture-boundary--\r\n"))
    }

    func testSubmitUsesFileUploadWithCanonicalIdempotencyAndAccepts202And200() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("scan bytes".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = authenticatedClient(configuration: configuration)
        for code in [202, 200] {
            AreaTargetTestURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/v1/jobs")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), self.jobID)
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=AreaTarget-") == true)
                XCTAssertGreaterThan(Int(request.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0, 10)
                XCTAssertNil(request.httpBody, "Upload bytes must stay file backed")
                return (code, self.jobJSON())
            }
            let job = try await client.submit(archiveURL: input, jobID: jobID, token: token, profile: "fast", uvUnwrap: true, progress: { _ in })
            XCTAssertEqual(job.jobID, jobID)
        }
    }

    func testNoFractionISODateAcceptedAndHTMLFailureIsSanitized() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = authenticatedClient(configuration: configuration)
        AreaTargetTestURLProtocol.handler = { _ in (200, Data(String(decoding: self.jobJSON(), as: UTF8.self).replacingOccurrences(of: ".123Z", with: "Z").utf8)) }
        let job = try await client.status(jobID: jobID, token: token)
        XCTAssertEqual(job.createdAt.timeIntervalSince1970, 1_791_072_000, accuracy: 0.001)
        AreaTargetTestURLProtocol.handler = { _ in (500, Data("<html>secret server stack</html>".utf8)) }
        do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted server failure") }
        catch {
            guard case .server(let code, let problem, _) = error as? AreaTargetAPIError else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(problem.code, "http_500")
            XCTAssertFalse(problem.message.contains("secret"))
        }
    }

    func testOversizedJSONAndWrongResponseHostAreRejected() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = authenticatedClient(configuration: configuration)
        AreaTargetTestURLProtocol.handler = { _ in (200, Data(repeating: 32, count: 65_537)) }
        do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted oversized JSON") }
        catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
        AreaTargetTestURLProtocol.responseURL = URL(string: "https://evil.test/jobs")
        defer { AreaTargetTestURLProtocol.responseURL = nil }
        AreaTargetTestURLProtocol.handler = { _ in (200, self.jobJSON()) }
        do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted wrong host") }
        catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
    }

    func testResultURLCannotChangeHostOrCarrySecrets() throws {
        for url in ["https://evil.test/api/v1/jobs/\(jobID)/result", "//evil.test/result", "/api/v1/jobs/\(jobID)/result?token=secret", "/api/v1/jobs/OTHER/result"] {
            let result = AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: 10, sha256: token, url: url, expiresAt: Date())
            XCTAssertThrowsError(try AreaTargetAPIClient.validateResult(result, jobID: jobID))
        }
    }

    func testDownloadUsesBearerFixedResultEndpointAndReturnsVerifiedOwnedFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let bytes = Data("small result fixture".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let result = AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: Int64(bytes.count), sha256: hash, url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(3600))
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/v1/jobs/\(self.jobID)/result")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            XCTAssertNil(request.url?.query)
            return (200, bytes)
        }
        let file = try await authenticatedClient(configuration: configuration).download(jobID: jobID, token: token, result: result, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("area-target-download-"))
    }

    func testDownloadDigestMismatchNeverReturnsFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let result = AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: 4, sha256: String(repeating: "0", count: 64), url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(3600))
        AreaTargetTestURLProtocol.handler = { _ in (200, Data([1,2,3,4])) }
        do { _ = try await authenticatedClient(configuration: configuration).download(jobID: jobID, token: token, result: result, progress: { _ in }); XCTFail("accepted digest mismatch") }
        catch { guard case .invalidResult = error as? AreaTargetAPIError else { return XCTFail("unexpected \(error)") } }
    }

    func testProcessingRequirementsUsesFixedHostWithServiceSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/v1/processing-requirements")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.query)
            return (200, self.requirementsJSON())
        }
        let requirements = try await authenticatedClient(configuration: configuration).fetchProcessingRequirements()
        XCTAssertEqual(requirements.preparationPolicy(for: "fast")?.maxFrames, 80)
        XCTAssertEqual(requirements.preparationPolicy(for: "quality")?.maximumLongEdge, 1600)
        XCTAssertEqual(requirements.preparationPolicy(for: "fast")?.maximumTotalPixels, 200_000_000)
    }

    func testUnknownOrUnsafePreparationPolicyCannotDriveClientTransforms() throws {
        for (old, new) in [("mobile-scan-preparation-v1", "future-policy"), ("\"policyVersion\":1", "\"policyVersion\":2"),
            ("\"maxFrames\":80", "\"maxFrames\":0"), ("\"maximumLongEdge\":1600", "\"maximumLongEdge\":9000"),
            ("\"maximumMetadataBytes\":8388608", "\"maximumMetadataBytes\":999999999") ] {
            let data = Data(String(decoding: requirementsJSON(), as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
            let requirements = try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: data)
            XCTAssertNil(requirements.preparationPolicy(for: "fast"))
        }
    }

    func testV2RequirementsAcceptOnlyFrozenCapacityAndImageBudgets() throws {
        for tier in [100, 500] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: requirementsJSON()) as? [String: Any])
            value["policy"] = "mobile-scan-preparation-v2"; value["policyVersion"] = 2; value["capacityTier"] = tier
            value["profiles"] = ["fast": ["maxFrames": tier, "maximumLongEdge": 1600, "minimumLongEdge": 1024,
                "maximumTotalPixels": tier == 100 ? 200_000_000 : 600_000_000]]
            func decode(_ object: [String: Any]) throws -> AreaTargetProcessingRequirements {
                try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object))
            }
            XCTAssertEqual(try decode(value).preparationPolicy(for: "fast")?.maxFrames, tier)
            for mutation in ["capacityTier", "policyVersion", "schemaVersion"] {
                var unsafe = value; unsafe[mutation] = 999
                XCTAssertNil(try decode(unsafe).preparationPolicy(for: "fast"), mutation)
            }
            var unsafe = value
            unsafe["profiles"] = ["fast": ["maxFrames": tier, "maximumLongEdge": 1600, "minimumLongEdge": 1000,
                "maximumTotalPixels": tier == 100 ? 200_000_000 : 600_000_000]]
            XCTAssertNil(try decode(unsafe).preparationPolicy(for: "fast"))
        }
    }

    func testCriticalFrameProtectionCapabilityIsExactAndOptionalForV2() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: requirementsJSON()) as? [String: Any])
        object["policy"] = "mobile-scan-preparation-v2"; object["policyVersion"] = 2; object["capacityTier"] = 100
        object["profiles"] = ["fast": ["maxFrames": 100, "maximumLongEdge": 1600, "minimumLongEdge": 1024, "maximumTotalPixels": 200_000_000]]
        let capability: [String: Any] = ["version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
            "maximumProtectedFrames": 8, "maximumProtectedLongEdge": 1920, "sharpnessThreshold": 16, "contrastThreshold": 20]
        func decode(_ record: [String: Any]) throws -> AreaTargetProcessingRequirements {
            try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: record))
        }
        XCTAssertNotNil(try decode(object).preparationPolicy(for: "fast"))
        object["criticalFrameProtection"] = capability
        let value = try decode(object)
        XCTAssertNotNil(value.preparationPolicy(for: "fast"))
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(roundTrip["criticalFrameProtection"] as? NSDictionary, capability as NSDictionary)
        for key in capability.keys {
            var incomplete = capability; incomplete.removeValue(forKey: key)
            var invalid = object; invalid["criticalFrameProtection"] = incomplete
            XCTAssertThrowsError(try decode(invalid), key)
        }
        for (key, replacement) in ["version": "future", "riskVersion": "future", "maximumProtectedFrames": 9,
            "maximumProtectedLongEdge": 2000, "sharpnessThreshold": 17, "contrastThreshold": 21, "unexpected": 1] as [String: Any] {
            var altered = capability; altered[key] = replacement
            var invalid = object; invalid["criticalFrameProtection"] = altered
            XCTAssertThrowsError(try decode(invalid), key)
        }
        for bad in [NSNull(), true, ["maximumProtectedFrames": true]] as [Any] {
            var invalid = object; invalid["criticalFrameProtection"] = bad
            XCTAssertThrowsError(try decode(invalid))
        }
        object["policy"] = "mobile-scan-preparation-v1"; object["policyVersion"] = 1
        XCTAssertNil(try decode(object).preparationPolicy(for: "fast"))
    }

    func testExplicitV2NegotiationToleratesLegacyResponseAndConfinesQueryToRequirements() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://at.3dugc.com/api/v1/processing-requirements?policy=mobile-scan-preparation-v2")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            return (200, self.requirementsJSON())
        }
        let requirements = try await authenticatedClient(configuration: configuration).fetchProcessingRequirements(policy: "mobile-scan-preparation-v2")
        XCTAssertEqual(requirements.preparationPolicy(for: "fast")?.maxFrames, 80)
        for value in ["https://at.3dugc.com/api/v1/jobs?policy=mobile-scan-preparation-v2",
                      "https://at.3dugc.com/api/v1/processing-requirements?policy=future-policy",
                      "https://at.3dugc.com/api/v1/processing-requirements?policy=mobile-scan-preparation-v2&token=secret"] {
            XCTAssertFalse(AreaTargetServerOrigin.current.allows(try XCTUnwrap(URL(string: value))))
        }
    }

    func testCriticalProtectionDecoderValidatesItsSourceCountAndPolicy() throws {
        var object: [String: Any] = ["schemaVersion": 1, "policy": "mobile-scan-preparation-v2", "policyVersion": 2,
            "profile": "fast", "preparedBy": "client", "originalFrameCount": 2, "selectedFrameCount": 2,
            "selectedIndices": [0, 1], "processedPixelCount": 20_000, "resizedFrameCount": 0,
            "maximumOutputLongEdge": 100, "scaleDigest": String(repeating: "a", count: 64)]
        let protection: [String: Any] = ["version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
            "protectedIndices": [1], "candidateFrameCount": 2]
        object["criticalFrameProtection"] = protection
        func decode(_ value: [String: Any]) throws -> AreaTargetClientPreparation {
            try JSONDecoder().decode(AreaTargetClientPreparation.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertNotNil(try decode(object))
        for (key, value) in ["protectedIndices": [2], "candidateFrameCount": 3] as [String: Any] {
            var cap = protection; cap[key] = value
            var invalid = object; invalid["criticalFrameProtection"] = cap
            XCTAssertThrowsError(try decode(invalid), key)
        }
        for (key, value) in ["policy": "mobile-scan-preparation-v1", "policyVersion": 1, "originalFrameCount": 0] as [String: Any] {
            var invalid = object; invalid[key] = value
            XCTAssertThrowsError(try decode(invalid), key)
        }
        object["criticalFrameProtection"] = ["version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
            "protectedIndices": [], "candidateFrameCount": 0]
        XCTAssertNotNil(try decode(object))
    }

    func testCriticalCapabilityRejectsIntegralFloatAndBooleanTokensAtResponseBoundary() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: requirementsJSON()) as? [String: Any])
        object["policy"] = "mobile-scan-preparation-v2"; object["policyVersion"] = 2; object["capacityTier"] = 100
        object["profiles"] = ["fast": ["maxFrames": 100, "maximumLongEdge": 1600, "minimumLongEdge": 1024, "maximumTotalPixels": 200_000_000]]
        object["criticalFrameProtection"] = ["version": "critical-frame-protection-v1", "riskVersion": "gray-quality-risk-v1",
            "maximumProtectedFrames": 8, "maximumProtectedLongEdge": 1920, "sharpnessThreshold": 16, "contrastThreshold": 20]
        let original = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        for (old, new) in [("\"maximumProtectedFrames\":8", "\"maximumProtectedFrames\":8.0"),
            ("\"maximumProtectedFrames\":8", "\"maximumProtectedFrames\":8e0"),
            ("\"maximumProtectedLongEdge\":1920", "\"maximumProtectedLongEdge\":1920.0"),
            ("\"sharpnessThreshold\":16", "\"sharpnessThreshold\":16.0"),
            ("\"contrastThreshold\":20", "\"contrastThreshold\":20.0"),
            ("\"maximumProtectedFrames\":8", "\"maximumProtectedFrames\":true")] {
            let altered = original.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(altered, original)
            AreaTargetTestURLProtocol.handler = { _ in (200, Data(altered.utf8)) }
            do { _ = try await authenticatedClient(configuration: configuration).fetchProcessingRequirements(policy: "mobile-scan-preparation-v2"); XCTFail("accepted " + new) }
            catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
        }
    }

    func testUploadSelectionDigestMatchesFrozenPythonCanonicalRecord() throws {
        XCTAssertEqual(try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1, 2, 99]),
            "37998e40ccd2c192ea6c0af84ac0c491e546ca4d2f8ef7cff3d231d1ac9af356")
    }

    func testMalformedRequirementsAreSanitizedAsInvalidResponse() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        AreaTargetTestURLProtocol.handler = { _ in (200, Data(#"{"schemaVersion":true,"path":"secret"}"#.utf8)) }
        do { _ = try await authenticatedClient(configuration: configuration).fetchProcessingRequirements(); XCTFail("accepted malformed requirements") }
        catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse) }
    }

    func testLegacyClientKeepsRequirementsSubmitStatusAndDownloadOnLegacyOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        let client = authenticatedClient(origin: .legacy, configuration: configuration)
        let bytes = Data([1, 2, 3, 4])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var paths: [String] = []
        AreaTargetTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "area-target.p.01xr.com")
            XCTAssertEqual(request.url?.scheme, "https")
            let path = request.url!.path
            paths.append(path)
            if path.hasSuffix("processing-requirements") {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, self.requirementsJSON())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
            if path.hasSuffix("/result") { return (200, bytes) }
            return (request.httpMethod == "POST" ? 202 : 200, self.jobJSON())
        }
        _ = try await client.fetchProcessingRequirements()
        _ = try await client.submit(archiveURL: file, jobID: jobID, token: token, profile: "fast", uvUnwrap: true, progress: { _ in })
        _ = try await client.status(jobID: jobID, token: token)
        let result = AreaTargetResult(format: "area-target-bundle", filename: "result.zip", sizeBytes: 4,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(3600))
        let downloaded = try await client.download(jobID: jobID, token: token, result: result, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        XCTAssertEqual(paths, ["/api/v1/processing-requirements", "/api/v1/jobs", "/api/v1/jobs/\(jobID)", "/api/v1/jobs/\(jobID)/result"])
    }

    func testEachClientRejectsOtherOriginAndURLAuthorityOrSecretChanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        defer { AreaTargetTestURLProtocol.responseURL = nil }
        AreaTargetTestURLProtocol.handler = { _ in (200, self.jobJSON()) }
        for origin in AreaTargetServerOrigin.allCases {
            let client = authenticatedClient(origin: origin, configuration: configuration)
            let host = origin.baseURL.host!
            let other = origin == .current ? "area-target.p.01xr.com" : "at.3dugc.com"
            for address in ["https://\(other)/api/v1/jobs/\(jobID)", "http://\(host)/jobs",
                "https://\(host):443/jobs", "https://user@\(host)/jobs", "https://\(host)/jobs?token=secret",
                "https://\(host)/jobs#secret", "https://evil.test/jobs"] {
                let url = try XCTUnwrap(URL(string: address))
                XCTAssertFalse(origin.allows(url), address)
                AreaTargetTestURLProtocol.responseURL = url
                do { _ = try await client.status(jobID: jobID, token: token); XCTFail("accepted foreign or unsafe response") }
                catch { XCTAssertEqual(error as? AreaTargetAPIError, .invalidResponse, address) }
            }
        }
    }

    func testRedirectNeverForwardsBearerToAnyOtherRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        defer { AreaTargetTestURLProtocol.redirectURL = nil }
        for origin in AreaTargetServerOrigin.allCases {
            var hosts: [String] = []
            let other = origin == .current ? AreaTargetServerOrigin.legacy : .current
            AreaTargetTestURLProtocol.redirectURL = other.baseURL.appendingPathComponent("api/v1/jobs/\(jobID)")
            AreaTargetTestURLProtocol.handler = { request in
                hosts.append(request.url!.host!)
                return (302, Data())
            }
            do { _ = try await authenticatedClient(origin: origin, configuration: configuration).status(jobID: jobID, token: token); XCTFail("redirect must not produce a successful job") }
            catch { /* The rejected redirect may be an HTTP error or cancellation. */ }
            XCTAssertEqual(hosts, [origin.baseURL.host!], "Do not issue any redirected capability request")
        }
    }

    func testNotFoundNeverRetriesTheCapabilityOnAnotherOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AreaTargetTestURLProtocol.self]
        for origin in AreaTargetServerOrigin.allCases {
            var calls = 0
            AreaTargetTestURLProtocol.handler = { request in
                calls += 1
                XCTAssertEqual(request.url?.host, origin.baseURL.host)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Area-Target-Session"), String(repeating: "b", count: 64))
                return (404, Data(#"{"error":{"code":"job_not_found","message":"missing","retryable":false}}"#.utf8))
            }
            do { _ = try await authenticatedClient(origin: origin, configuration: configuration).status(jobID: jobID, token: token); XCTFail("accepted missing job") }
            catch { guard case .server(let status, _, _) = error as? AreaTargetAPIError else { return XCTFail("unexpected error") }; XCTAssertEqual(status, 404) }
            XCTAssertEqual(calls, 1)
        }
    }

    private func authenticatedClient(origin: AreaTargetServerOrigin = .current, configuration: URLSessionConfiguration) -> AreaTargetAPIClient {
        AreaTargetAPIClient(origin: origin, configuration: configuration, sessionStore: AreaServiceTestSessions.authenticated())
    }

    private func requirementsJSON() -> Data {
        Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profiles":{"fast":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000},"quality":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000}},"safety":{"maximumRequestBytes":536870912,"maximumExpandedBytes":524288000,"maximumArchiveEntries":10000,"maximumSourceFrameCount":10000,"maximumImagePixels":32000000,"maximumImageDimension":8192,"maximumMetadataBytes":8388608}}"#.utf8)
    }

    private func jobJSON() -> Data {
        Data("{\"job_id\":\"\(jobID)\",\"status\":\"queued\",\"progress\":0,\"stage\":\"queued\",\"message\":\"Queued\",\"profile\":\"fast\",\"uv_unwrap\":true,\"created_at\":\"2026-10-04T00:00:00.123Z\",\"finished_at\":null,\"expires_at\":null,\"error\":null,\"result\":null}".utf8)
    }
}

private final class AreaTargetTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var headers: [String: String] = [:]
    static var responseURL: URL?
    static var redirectURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
            if let redirect = Self.redirectURL {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}


final class AreaServiceTestSessions: AreaTargetServiceSessionStoring {
    private var values: [AreaTargetServerOrigin: AreaTargetServiceSession] = [:]
    private let lock = NSLock()
    var failLoads = false
    var failRemovals = false
    private(set) var removeAttempts = 0
    static func authenticated() -> AreaServiceTestSessions {
        let store = AreaServiceTestSessions()
        for origin in AreaTargetServerOrigin.allCases {
            try! store.save(AreaTargetServiceSession(token: String(repeating: "b", count: 64), username: "scanner",
                expiresAt: Date().addingTimeInterval(3600), csrfToken: String(repeating: "c", count: 64)), origin: origin)
        }
        return store
    }
    func load(origin: AreaTargetServerOrigin) throws -> AreaTargetServiceSession? {
        lock.lock(); defer { lock.unlock() }
        if failLoads { throw AreaTargetAPIError.credentialStorage }
        return values[origin]
    }
    func save(_ session: AreaTargetServiceSession, origin: AreaTargetServerOrigin) throws { lock.lock(); defer { lock.unlock() }; values[origin] = session }
    func remove(origin: AreaTargetServerOrigin) throws {
        lock.lock(); defer { lock.unlock() }
        removeAttempts += 1
        if failRemovals { throw AreaTargetAPIError.credentialStorage }
        values.removeValue(forKey: origin)
    }
}
