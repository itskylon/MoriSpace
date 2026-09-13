import XCTest
@testable import MoriPhotos

final class MockURLProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.responder!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SynologyClientTests: XCTestCase {
    private let credentials = NASCredentials(address: "https://nas.example.com:5001", username: "测试+user", password: "a+b&c=密 码")
    private func client() throws -> SynologyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return try SynologyClient(address: credentials.address, session: URLSession(configuration: config))
    }
    private static func fields(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(data: data, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) }
    private static var info: [String: Any] {
        var result: [String: Any] = ["SYNO.API.Auth": ["path": "auth.cgi", "minVersion": 1, "maxVersion": 7], "SYNO.API.Info": ["path": "query.cgi", "minVersion": 1, "maxVersion": 1]]
        for prefix in ["SYNO.Foto", "SYNO.FotoTeam"] {
            for suffix in ["Browse.Item", "Browse.Folder", "Thumbnail", "Download"] {
                result[prefix + "." + suffix] = ["path": "entry.cgi", "minVersion": 1, "maxVersion": 4, "requestFormat": "JSON"]
            }
        }
        return result
    }
    private static func authReply(_ fields: [String: String]) throws -> Data? {
        if fields["api"] == "SYNO.API.Info" { return try json(["success": true, "data": info]) }
        if fields["method"] == "login" { return try json(["success": true, "data": ["sid": "test-session", "synotoken": "test-token"]]) }
        return nil
    }
    override func tearDown() { MockURLProtocol.responder = nil; super.tearDown() }

    func testAddressValidationAndNormalization() throws {
        XCTAssertEqual(try SynologyClient.normalizedAddress(" https://nas.example.com/photo/webapi/ ").absoluteString, "https://nas.example.com/photo")
        for input in ["http://nas.example.com", "https://user:secret@nas.example.com", "https://nas.example.com?secret=x", "https://quickconnect.to/user", "not-a-url"] {
            XCTAssertThrowsError(try SynologyClient.normalizedAddress(input))
        }
    }

    func testLoginKeepsSecretsOutOfURLAndPreservesSpecialCharacters() async throws {
        let expected = credentials
        MockURLProtocol.responder = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            let fields = Self.fields(request)
            if fields["method"] == "login" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"))
                XCTAssertEqual(request.url?.path, "/webapi/auth.cgi")
                XCTAssertEqual(fields["account"], expected.username)
                XCTAssertEqual(fields["passwd"], expected.password)
                XCTAssertEqual(fields["otp_code"], "123456")
                XCTAssertEqual(fields["version"], "6")
            }
            return (200, try Self.authReply(fields)!)
        }
        try await client().login(credentials, otp: "123456")
    }

    func testSharedSpaceUsesJSONParametersAndAuthenticatedPagination() async throws {
        MockURLProtocol.responder = { request in
            let fields = Self.fields(request)
            if let data = try Self.authReply(fields) { return (200, data) }
            XCTAssertEqual(fields["api"], "SYNO.FotoTeam.Browse.Item")
            XCTAssertEqual(fields["offset"], "90")
            XCTAssertEqual(fields["folder_id"], "12")
            XCTAssertEqual(fields["sort_by"], "\"takentime\"")
            XCTAssertEqual(fields["_sid"], "test-session")
            XCTAssertEqual(fields["SynoToken"], "test-token")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=test-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "test-token")
            XCTAssertEqual(fields["additional"], "[\"thumbnail\",\"resolution\"]")
            return (200, try Self.json(["success": true, "data": ["list": [["id": 7, "filename": "旅行.heic", "time": 1720000000, "additional": ["thumbnail": ["unit_id": 7, "cache_key": "7_ab"]]]]]]))
        }
        let client = try client()
        try await client.login(credentials, otp: "")
        let photos = try await client.photos(space: .shared, folder: 12, offset: 90)
        XCTAssertEqual(photos.first?.filename, "旅行.heic")
        XCTAssertEqual(photos.first?.additional?.thumbnail?.cache_key, "7_ab")
    }

    func testExpiredSessionIsAnErrorRatherThanAnEmptyGallery() async throws {
        MockURLProtocol.responder = { request in
            if let data = try Self.authReply(Self.fields(request)) { return (200, data) }
            return (200, try Self.json(["success": false, "error": ["code": 119]]))
        }
        let client = try client()
        try await client.login(credentials, otp: "")
        do { _ = try await client.photos(space: .personal, offset: 0); XCTFail("Expected session failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("119")); XCTAssertTrue(error.localizedDescription.contains("重新登录")) }
    }

    func testPhotosCanAuthenticateUsingTheDSMCookie() async throws {
        MockURLProtocol.responder = { request in
            let fields = Self.fields(request)
            if let data = try Self.authReply(fields) { return (200, data) }
            guard request.value(forHTTPHeaderField: "Cookie") == "id=test-session",
                  request.value(forHTTPHeaderField: "X-SYNO-TOKEN") == "test-token" else {
                return (200, try Self.json(["success": false, "error": ["code": 119]]))
            }
            return (200, try Self.json(["success": true, "data": ["list": [["id": 1, "filename": "sample.jpg"]]]]))
        }
        let client = try client()
        try await client.login(credentials, otp: "")
        let photos = try await client.photos(space: .personal, offset: 0)
        XCTAssertEqual(photos.map(\.id), [1])
    }

    func testInvalidSessionValuesCannotBecomeCookieHeaders() async throws {
        for sid in ["", "sid; injected=value", "sid\r\nInjected: value", "会话"] {
            MockURLProtocol.responder = { request in
                let fields = Self.fields(request)
                if fields["api"] == "SYNO.API.Info" { return (200, try Self.json(["success": true, "data": Self.info])) }
                return (200, try Self.json(["success": true, "data": ["sid": sid]]))
            }
            do { try await client().login(credentials, otp: ""); XCTFail("Expected invalid session rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("格式")) }
        }
    }

    func testBlockedLoginExplainsIPBlockAndDoesNotRetryAuthentication() async throws {
        var loginAttempts = 0
        MockURLProtocol.responder = { request in
            let fields = Self.fields(request)
            if fields["api"] == "SYNO.API.Info" {
                return (200, try Self.json(["success": true, "data": Self.info]))
            }
            XCTAssertEqual(fields["method"], "login")
            loginAttempts += 1
            return (200, try Self.json(["success": false, "error": ["code": 407]]))
        }
        do { try await client().login(credentials, otp: ""); XCTFail("Expected blocked source IP") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("IP 地址已被 NAS 封锁（407）"))
            XCTAssertFalse(error.localizedDescription.contains("额外的身份验证"))
        }
        XCTAssertEqual(loginAttempts, 1)
    }

    func testMalformedServerAndRedirectResponsesAreRejected() async throws {
        for status in [200, 302, 503] {
            MockURLProtocol.responder = { _ in (status, Data("<html>login portal</html>".utf8)) }
            do { try await client().login(credentials, otp: ""); XCTFail("Expected invalid server response") }
            catch {
                if status == 302 { XCTAssertTrue(error.localizedDescription.contains("重定向")) }
                if status == 503 { XCTAssertTrue(error.localizedDescription.contains("503")) }
                if status == 200 { XCTAssertTrue(error.localizedDescription.contains("格式")) }
            }
        }
    }

    @MainActor
    func testBrowserPaginatesFoldersAndMergesPhotoPages() async throws {
        MockURLProtocol.responder = { request in
            let fields = Self.fields(request)
            if let data = try Self.authReply(fields) { return (200, data) }
            let offset = Int(fields["offset"] ?? "0")!
            let list: [[String: Any]]
            if fields["api"]!.hasSuffix("Browse.Folder") {
                list = offset == 0 ? (1...100).map { ["id": $0, "name": "/folder\($0)", "parent": 0] } : [["id": 101, "name": "/last", "parent": 0]]
            } else {
                list = offset == 0 ? (1...90).map { ["id": $0, "filename": "\($0).jpg"] } : [["id": 90, "filename": "duplicate.jpg"], ["id": 91, "filename": "last.jpg"]]
            }
            return (200, try Self.json(["success": true, "data": ["list": list]]))
        }
        let client = try client()
        try await client.login(credentials, otp: "")
        let store = NASBrowserStore()
        await store.reset(client: client, space: .personal, folder: nil)
        XCTAssertEqual(store.folders.count, 101)
        XCTAssertEqual(store.photos.count, 90)
        XCTAssertTrue(store.hasMore)
        await store.loadMore(client: client, space: .personal, folder: nil)
        XCTAssertEqual(store.photos.count, 91)
        XCTAssertFalse(store.hasMore)
        XCTAssertNil(store.error)
    }
}
