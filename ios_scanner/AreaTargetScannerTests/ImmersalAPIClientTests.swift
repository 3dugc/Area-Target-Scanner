import XCTest
import CryptoKit
@testable import AreaTargetScanner

final class ImmersalAPIClientTests: XCTestCase {
    private var client: ImmersalAPIClient!
    private var session: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmersalURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = ImmersalAPIClient(session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ImmersalURLProtocol.handler = nil
    }

    func testDownloadMapUsesAuthenticatedPOSTAndVerifiesDecodedBytes() async throws {
        let bytes = Data([0, 1, 2, 3, 255])
        ImmersalURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://api.immersal.com/mapb64")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["token"] as? String, "fixture-token")
            XCTAssertEqual(json["id"] as? Int, 123)
            return (200, try Self.mapResponse(bytes))
        }
        let result = try await client.downloadMap(mapID: 123, token: "fixture-token")
        XCTAssertEqual(result, bytes)
    }

    func testDownloadAcceptsUppercaseSHA256Hex() async throws {
        let bytes = Data([7, 8, 9])
        ImmersalURLProtocol.handler = { _, _ in
            (200, try Self.mapResponse(bytes, hash: Self.hash(bytes).uppercased()))
        }
        let downloaded = try await client.downloadMap(mapID: 123, token: "fixture-token")
        XCTAssertEqual(downloaded, bytes)
    }

    func testDownloadRejectsMissingOrMalformedBase64HashAndMismatchedDigest() async throws {
        let bytes = Data([255])
        let validHash = Self.hash(bytes)
        let cases: [[String: Any]] = [
            ["error": "none"],
            ["error": "none", "b64": "", "sha256_al": Self.hash(Data())],
            ["error": "none", "b64": "###", "sha256_al": validHash],
            ["error": "none", "b64": "/w==\n", "sha256_al": validHash],
            ["error": "none", "b64": "/x==", "sha256_al": validHash],
            ["error": "none", "b64": bytes.base64EncodedString(), "sha256_al": "abc"],
            ["error": "none", "b64": bytes.base64EncodedString(), "sha256_al": String(repeating: "g", count: 64)],
            ["error": "none", "b64": bytes.base64EncodedString(), "sha256_al": String(repeating: "0", count: 64)]
        ]
        for json in cases {
            ImmersalURLProtocol.handler = { _, _ in (200, try JSONSerialization.data(withJSONObject: json)) }
            do {
                _ = try await client.downloadMap(mapID: 123, token: "fixture-token")
                XCTFail("Invalid map payload must fail")
            } catch { XCTAssertEqual(error as? ImmersalAPIError, .invalidResponse) }
        }
    }

    func testDownloadEnforcesDecodedMapSizeLimit() async throws {
        let smallClient = ImmersalAPIClient(session: session, maximumMapBytes: 3)
        ImmersalURLProtocol.handler = { _, _ in (200, try Self.mapResponse(Data([1, 2, 3, 4]))) }
        do {
            _ = try await smallClient.downloadMap(mapID: 123, token: "fixture-token")
            XCTFail("Oversized map must fail")
        } catch { XCTAssertEqual(error as? ImmersalAPIError, .invalidResponse) }
        ImmersalURLProtocol.handler = { _, _ in (200, try Self.mapResponse(Data([1, 2, 3]))) }
        let downloaded = try await smallClient.downloadMap(mapID: 123, token: "fixture-token")
        XCTAssertEqual(downloaded, Data([1, 2, 3]))
    }

    func testDownloadRejectsInvalidMapIdentityBeforeNetworkRequest() async {
        ImmersalURLProtocol.handler = { _, _ in
            XCTFail("Invalid map ID must never make a request")
            return (200, Data())
        }
        for mapID in [0, -1] {
            do {
                _ = try await client.downloadMap(mapID: mapID, token: "fixture-token")
                XCTFail("Invalid map ID must fail")
            } catch { XCTAssertEqual(error as? ImmersalAPIError, .invalidResponse) }
        }
    }

    func testMapDownloadPropagatesAuthenticationAndHTTPFailures() async {
        for (status, payload, expected) in [
            (200, Data(#"{"error":"auth"}"#.utf8), ImmersalAPIError.authentication),
            (503, Data("unavailable".utf8), ImmersalAPIError.http(503))
        ] {
            ImmersalURLProtocol.handler = { _, _ in (status, payload) }
            do {
                _ = try await client.downloadMap(mapID: 123, token: "fixture-token")
                XCTFail("Rejected download must fail")
            } catch { XCTAssertEqual(error as? ImmersalAPIError, expected) }
        }
    }

    func testDownloadCancellationDoesNotReturnLateMapBytes() async {
        let started = expectation(description: "download request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        ImmersalURLProtocol.handler = { _, _ in
            started.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 3)
            return (200, try Self.mapResponse(Data([1, 2, 3])))
        }
        let download = Task { try await client.downloadMap(mapID: 123, token: "fixture-token") }
        await fulfillment(of: [started], timeout: 3)
        download.cancel()
        releaseResponse.signal()
        do {
            _ = try await download.value
            XCTFail("Cancelled download must not publish map bytes")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mapResponse(_ bytes: Data, hash: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": "none", "b64": bytes.base64EncodedString(), "sha256_al": hash ?? Self.hash(bytes)])
    }

    func testLoginUsesEmailPasswordAndDecodesToken() async throws {
        ImmersalURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://api.immersal.com/login")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
            XCTAssertEqual(json, ["login": "person@example.com", "password": "secret"])
            return (200, Data(#"{"error":"none","userId":17,"token":"test-token"}"#.utf8))
        }
        let credential = try await client.login(email: "person@example.com", password: "secret")
        XCTAssertEqual(credential.userID, 17)
        XCTAssertEqual(credential.email, "person@example.com")
        XCTAssertEqual(credential.token, "test-token")
    }

    func testCaptureSendsJSONNullPNGAndNoLocalImagePath() async throws {
        let png = Data([137, 80, 78, 71, 0, 1, 2])
        ImmersalURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/capture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            let delimiter = try XCTUnwrap(body.firstIndex(of: 0))
            let json = try JSONSerialization.jsonObject(with: body.prefix(upTo: delimiter)) as! [String: Any]
            XCTAssertEqual(json["token"] as? String, "test-token")
            XCTAssertEqual(json["index"] as? Int, 9)
            XCTAssertNil(json["imagePath"])
            XCTAssertEqual(body.suffix(from: delimiter + 1), png)
            return (200, Data(#"{"error":"none","path":"image"}"#.utf8))
        }
        try await client.capture(frame: ImmersalUploadFrame(png: png, metadata: Data(#"{"index":9,"run":10}"#.utf8)), token: "test-token")
    }

    func testAuthenticationErrorInHTTP200IsNotSuccess() async throws {
        ImmersalURLProtocol.handler = { _, _ in (200, Data(#"{"error":"auth"}"#.utf8)) }
        do {
            _ = try await client.status(token: "invalid")
            XCTFail("Expected authentication error")
        } catch { XCTAssertEqual(error as? ImmersalAPIError, .authentication) }
    }

    func testMalformedSuccessAndHTTPFailureAreRejected() async throws {
        ImmersalURLProtocol.handler = { _, _ in (200, Data(#"{"error":"none"}"#.utf8)) }
        do {
            _ = try await client.construct(name: "Map123", token: "test")
            XCTFail("Missing map ID must fail")
        } catch { XCTAssertEqual(error as? ImmersalAPIError, .invalidResponse) }
        ImmersalURLProtocol.handler = { _, _ in (503, Data("unavailable".utf8)) }
        do {
            _ = try await client.jobs(token: "test")
            XCTFail("Expected HTTP error")
        } catch { XCTAssertEqual(error as? ImmersalAPIError, .http(503)) }
    }

    func testConstructStatusClearAndJobsContracts() async throws {
        ImmersalURLProtocol.handler = { request, body in
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["token"] as? String, "test")
            switch request.url!.path {
            case "/construct":
                XCTAssertEqual(json["preservePoses"] as? Bool, true)
                XCTAssertEqual(json["name"] as? String, "Map123")
                return (200, Data(#"{"error":"none","id":123,"size":2}"#.utf8))
            case "/status": return (200, Data(#"{"error":"none","userId":17,"imageCount":2,"imageMax":100}"#.utf8))
            case "/clear":
                XCTAssertEqual(json["anchor"] as? Bool, true)
                return (200, Data(#"{"error":"none"}"#.utf8))
            default: return (200, Data(#"{"error":"none","jobs":[{"id":123,"size":2,"name":"Map123","status":"done","errno":"0"}]}"#.utf8))
            }
        }
        let status = try await client.status(token: "test")
        XCTAssertEqual(status.imageMax, 100)
        XCTAssertEqual(status.userID, 17)
        try await client.clear(token: "test")
        let map = try await client.construct(name: "Map123", token: "test")
        XCTAssertEqual(map.id, 123)
        let jobs = try await client.jobs(token: "test")
        XCTAssertEqual(jobs.first?.status, "done")
    }

    func testKeychainRoundTripDoesNotPersistPasswordAndDeletes() throws {
        let store = ImmersalKeychainStore(service: "test.immersal.\(UUID().uuidString)")
        defer { try? store.clear() }
        XCTAssertNil(try store.load())
        let credential = ImmersalCredential(email: "person@example.com", userID: 17, token: "test-token")
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)
        let encoded = String(data: try JSONEncoder().encode(credential), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("password"))
        try store.clear()
        XCTAssertNil(try store.load())
    }
}

private final class ImmersalURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let (status, data) = try Self.handler!(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
