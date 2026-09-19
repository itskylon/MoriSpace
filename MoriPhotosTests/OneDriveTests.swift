import XCTest
@testable import MoriPhotos

private final class OneDriveTestURLProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let responder = Self.responder else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try responder(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor OneDriveTokenProbe {
    private(set) var calls: [Bool] = []
    func token(forceRefresh: Bool) -> String {
        calls.append(forceRefresh)
        return forceRefresh ? "refreshed-test-token" : "initial-test-token"
    }
}

private final class OneDrivePersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [OneDriveTokenRecord] = []
    private var deleted: [String] = []
    var persistence: OneDriveTokenPersistence {
        OneDriveTokenPersistence(save: { record in
            self.lock.lock(); defer { self.lock.unlock() }; self.saved.append(record)
        }, delete: { clientID in
            self.lock.lock(); defer { self.lock.unlock() }; self.deleted.append(clientID)
        })
    }
    var records: [OneDriveTokenRecord] { lock.lock(); defer { lock.unlock() }; return saved }
    var deletedIDs: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
}

final class OneDriveTests: XCTestCase {
    private static let applicationID = "00000000-0000-4000-8000-000000000001"
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveTestURLProtocol.self]
        return configuration
    }
    private func client(probe: OneDriveTokenProbe = OneDriveTokenProbe()) -> OneDriveClient {
        return OneDriveClient(tokenProvider: { forceRefresh in
            await probe.token(forceRefresh: forceRefresh)
        }, configuration: configuration())
    }
    private static func json(_ object: Any, status: Int = 200) throws -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: object))
    }
    private static func item(_ id: String, name: String = "说明.txt", folder: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "size": 12, "lastModifiedDateTime": "2026-09-19T08:00:00Z", "eTag": "test-etag", "parentReference": ["driveId": "test-drive"], "webUrl": "https://onedrive.live.com/?id=test-item"]
        result[folder ? "folder" : "file"] = folder ? ["childCount": 2] : ["mimeType": "text/plain"]
        return result
    }
    override func tearDown() {
        OneDriveTestURLProtocol.responder = nil
        super.tearDown()
    }

    func testReadsDriveAccountAndGraphItemMetadata() async throws {
        OneDriveTestURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.host, "graph.microsoft.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer initial-test-token")
            if request.url?.path == "/v1.0/me/drive" {
                return try Self.json(["id": "test-drive", "name": "OneDrive", "driveType": "personal", "owner": ["user": ["displayName": "示例用户"]]])
            }
            return try Self.json(Self.item("test-item"))
        }
        let client = client()
        let account = try await client.account()
        XCTAssertEqual(account.driveID, "test-drive")
        XCTAssertEqual(account.displayName, "示例用户")
        let item = try await client.item(id: "test-item")
        XCTAssertEqual(item.id, "test-item")
        XCTAssertEqual(item.name, "说明.txt")
        XCTAssertEqual(item.size, 12)
        XCTAssertNotNil(item.modified)
        XCTAssertEqual(item.mimeType, "text/plain")
        XCTAssertEqual(item.driveID, "test-drive")
        XCTAssertFalse(item.isFolder)
    }

    func testChildrenUsesGraphContinuationURLWithoutLosingItsCursor() async throws {
        let continuation = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=abc%2Bxyz%3D&$top=100")!
        var requests = 0
        OneDriveTestURLProtocol.responder = { request in
            requests += 1
            if requests == 1 {
                XCTAssertEqual(request.url?.path, "/v1.0/me/drive/root/children")
                return try Self.json(["value": [Self.item("photos", name: "Photos", folder: true)], "@odata.nextLink": continuation.absoluteString])
            }
            XCTAssertEqual(request.url, continuation)
            return try Self.json(["value": [Self.item("next-page")]])
        }
        let client = client()
        let first = try await client.children(of: nil, nextLink: nil)
        XCTAssertEqual(first.items.map(\.id), ["photos"])
        XCTAssertTrue(first.items[0].isFolder)
        XCTAssertEqual(first.nextLink, continuation)
        let second = try await client.children(of: nil, nextLink: first.nextLink)
        XCTAssertEqual(second.items.map(\.id), ["next-page"])
        XCTAssertNil(second.nextLink)
        XCTAssertEqual(requests, 2)
    }

    func testItemIDIsEncodedAsASingleURLPathComponent() async throws {
        let identifier = "folder + 中文#?&"
        OneDriveTestURLProtocol.responder = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertNil(components.fragment)
            XCTAssertTrue(components.percentEncodedPath.contains("%23"))
            XCTAssertTrue(components.percentEncodedPath.contains("%3F"))
            let encodedID = String(components.percentEncodedPath.dropFirst("/v1.0/me/drive/items/".count))
            XCTAssertEqual(encodedID.removingPercentEncoding, identifier)
            return try Self.json(Self.item(identifier))
        }
        let item = try await client().item(id: identifier)
        XCTAssertEqual(item.id, identifier)
    }

    func testUntrustedContinuationIsRejectedBeforeSendingAnyToken() async throws {
        var requests = 0
        OneDriveTestURLProtocol.responder = { _ in requests += 1; return try Self.json(["value": []]) }
        let client = client()
        for value in ["https://foreign.example.invalid/v1.0/me/drive/root/children", "http://graph.microsoft.com/v1.0/me/drive/root/children", "https://graph.microsoft.com.foreign.example.invalid/v1.0/me/drive/root/children", "https://user:secret@graph.microsoft.com/v1.0/me/drive/root/children"] {
            do {
                _ = try await client.children(of: nil, nextLink: URL(string: value)!)
                XCTFail("Rejected continuation should not be fetched: \(value)")
            } catch {}
        }
        XCTAssertEqual(requests, 0)
    }

    func testContinuationFromServerCannotSwitchDriveOrCollection() async throws {
        let links = [
            "https://foreign.example.invalid/v1.0/me/drive/root/children?$skiptoken=cursor",
            "https://graph.microsoft.com/v1.0/users/another-user/drive/root/children?$skiptoken=cursor",
            "https://graph.microsoft.com/v1.0/me/drive/items/another-folder/children?$skiptoken=cursor"
        ]
        for link in links {
            OneDriveTestURLProtocol.responder = { _ in
                try Self.json(["value": [Self.item("local")], "@odata.nextLink": link])
            }
            do { _ = try await client().children(of: nil, nextLink: nil); XCTFail("Expected rejected server continuation") }
            catch { XCTAssertEqual(error as? OneDriveError, .unsafeURL) }
        }
    }

    func testUnauthorizedResponseRefreshesOnceThenSucceeds() async throws {
        let probe = OneDriveTokenProbe()
        var requests = 0
        OneDriveTestURLProtocol.responder = { request in
            requests += 1
            if requests == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer initial-test-token")
                return try Self.json(["error": ["code": "InvalidAuthenticationToken"]], status: 401)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-test-token")
            return try Self.json(Self.item("test-item"))
        }
        _ = try await client(probe: probe).item(id: "test-item")
        XCTAssertEqual(requests, 2)
        let calls = await probe.calls
        XCTAssertEqual(calls, [false, false, true])
    }

    func testUnauthorizedAfterRefreshStopsRatherThanLooping() async throws {
        let probe = OneDriveTokenProbe()
        var requests = 0
        OneDriveTestURLProtocol.responder = { _ in requests += 1; return try Self.json(["error": ["code": "InvalidAuthenticationToken"]], status: 401) }
        do { _ = try await client(probe: probe).item(id: "test-item"); XCTFail("Expected sign-in error") }
        catch {}
        XCTAssertEqual(requests, 2)
        let calls = await probe.calls
        XCTAssertEqual(calls, [false, false, true])
    }

    func testDownloadURLRejectsNonHTTPSAndEmbeddedCredentials() async throws {
        let client = client()
        for value in ["http://download.example.invalid/file", "file:///tmp/file", "https://user:secret@download.example.invalid/file"] {
            OneDriveTestURLProtocol.responder = { _ in
                var object = Self.item("test-item")
                object["@microsoft.graph.downloadUrl"] = value
                return try Self.json(object)
            }
            do { _ = try await client.downloadURL(for: "test-item"); XCTFail("Expected unsafe download URL rejection") }
            catch {}
        }
    }

    func testResolvingDownloadURLKeepsBearerOnlyOnGraphRequest() async throws {
        var hosts: [String] = []
        let expected = URL(string: "https://download.example.invalid/content?temporary=fixture")!
        OneDriveTestURLProtocol.responder = { request in
            hosts.append(request.url?.host ?? "")
            XCTAssertEqual(request.url?.host, "graph.microsoft.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer initial-test-token")
            var object = Self.item("test-item")
            object["@microsoft.graph.downloadUrl"] = expected.absoluteString
            return try Self.json(object)
        }
        let result = try await client().downloadURL(for: "test-item")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(hosts, ["graph.microsoft.com"])
    }

    func testPathTraversalAndEncodedSeparatorsAreRejectedBeforeNetworking() async throws {
        var requests = 0
        OneDriveTestURLProtocol.responder = { _ in requests += 1; return try Self.json(Self.item("anything")) }
        let client = client()
        for id in ["", ".", "..", "../other", "folder/file", "folder\\file", "folder%2Ffile", "nul\0id"] {
            do { _ = try await client.item(id: id); XCTFail("Expected unsafe item identity rejection") }
            catch { XCTAssertEqual(error as? OneDriveError, .invalidResponse) }
        }
        XCTAssertEqual(requests, 0)
    }

    func testRemoteShortcutsCannotBeReadAsItemsInTheCurrentDrive() async throws {
        var shortcut = Self.item("shortcut", name: "共享库", folder: true)
        shortcut["remoteItem"] = ["id": "foreign-item", "parentReference": ["driveId": "foreign-drive"]]
        let remoteItem = shortcut
        OneDriveTestURLProtocol.responder = { request in
            if request.url?.path.hasSuffix("children") == true {
                return try Self.json(["value": [remoteItem, Self.item("local")]])
            }
            return try Self.json(remoteItem)
        }
        let client = client()
        let page = try await client.children(of: nil, nextLink: nil)
        XCTAssertEqual(page.items.map(\.id), ["local"])
        do { _ = try await client.item(id: "shortcut"); XCTFail("Expected unsupported shortcut") }
        catch { XCTAssertEqual(error as? OneDriveError, .unsupportedShortcut) }
        do { _ = try await client.downloadURL(for: "shortcut"); XCTFail("Expected unsupported shortcut") }
        catch { XCTAssertEqual(error as? OneDriveError, .unsupportedShortcut) }
    }

    func testBusinessDriveUsesDriveNameWhenOwnerDisplayNameIsAbsent() async throws {
        OneDriveTestURLProtocol.responder = { _ in
            try Self.json(["id": "work-drive", "name": "工作文档", "driveType": "business"])
        }
        let account = try await client().account()
        XCTAssertEqual(account.driveID, "work-drive")
        XCTAssertEqual(account.displayName, "工作文档")
    }

    func testItemFromAnotherDriveIsRejectedAfterAccountResolution() async throws {
        OneDriveTestURLProtocol.responder = { request in
            if request.url?.path == "/v1.0/me/drive" {
                return try Self.json(["id": "my-drive", "name": "OneDrive"])
            }
            return try Self.json(Self.item("different-drive-item"))
        }
        let client = client()
        _ = try await client.account()
        do { _ = try await client.item(id: "different-drive-item"); XCTFail("Expected different-drive rejection") }
        catch { XCTAssertEqual(error as? OneDriveError, .unsupportedShortcut) }
    }

    func testPKCEUsesRFC7636SHA256VectorAndFreshRandomValues() throws {
        XCTAssertEqual(OneDrivePKCE.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try OneDrivePKCE.make(), second = try OneDrivePKCE.make()
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertEqual(first.state.count, 43)
        XCTAssertNotEqual(first.verifier, first.state)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertFalse(first.challenge.contains("="))
    }

    func testAuthorizationUsesReadOnlyPKCEWithoutClientSecret() throws {
        let url = try OneDriveOAuth.authorizationURL(clientID: Self.applicationID, state: "test-state", challenge: "test-challenge")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let fields = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.host, "login.microsoftonline.com")
        XCTAssertEqual(fields["response_type"], "code")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["code_challenge"], "test-challenge")
        XCTAssertEqual(fields["state"], "test-state")
        XCTAssertEqual(fields["redirect_uri"], OneDriveOAuth.redirectURI)
        XCTAssertTrue(fields["scope"]!.contains("Files.Read"))
        XCTAssertFalse(fields["scope"]!.contains("Write"))
        XCTAssertNil(fields["client_secret"])
    }

    func testTokenFormPreservesLiteralPlusAmpersandAndUnicode() throws {
        let encoded = String(data: OneDriveOAuth.formData(["code": "a+b&c=中文 value", "grant_type": "authorization_code"]), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("a%2Bb%26c%3D"))
        XCTAssertTrue(encoded.contains("%20value"))
        XCTAssertFalse(encoded.contains("+"))
        var components = URLComponents(); components.percentEncodedQuery = encoded
        let fields = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["code"], "a+b&c=中文 value")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
    }

    func testCallbackRequiresExactRedirectSingleStateAndSingleCode() throws {
        let valid = OneDriveOAuth.redirectURI + "?state=expected&code=test-code"
        XCTAssertEqual(try OneDriveOAuth.authorizationCode(callback: URL(string: valid)!, expectedState: "expected"), "test-code")
        for value in [
            OneDriveOAuth.redirectURI + "?state=wrong&code=test-code",
            OneDriveOAuth.redirectURI + "?state=expected&state=expected&code=test-code",
            OneDriveOAuth.redirectURI + "?state=expected&code=first&code=second",
            OneDriveOAuth.redirectURI + "?code=test-code",
            OneDriveOAuth.redirectURI + "/other?state=expected&code=test-code",
            "msauth.dev.kylon.MoriPhotos://other?state=expected&code=test-code",
            valid + "#fragment",
            valid + "&error=access_denied"
        ] {
            XCTAssertThrowsError(try OneDriveOAuth.authorizationCode(callback: URL(string: value)!, expectedState: "expected")) {
                XCTAssertEqual($0 as? OneDriveError, .invalidCallback)
            }
        }
        XCTAssertThrowsError(try OneDriveOAuth.authorizationCode(callback: URL(string: OneDriveOAuth.redirectURI + "?state=expected&error=access_denied")!, expectedState: "expected")) {
            XCTAssertEqual($0 as? OneDriveError, .cancelled)
        }
    }

    func testConcurrentRefreshSharesOneRequestAndPersistsRotatedToken() async throws {
        let persistence = OneDrivePersistenceProbe()
        var requests = 0
        OneDriveTestURLProtocol.responder = { request in
            requests += 1
            XCTAssertEqual(request.url, OneDriveOAuth.tokenURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            // Hold this synthetic response briefly so every caller reaches the in-flight refresh.
            Thread.sleep(forTimeInterval: 0.04)
            return try Self.json(["access_token": "new-test-access", "refresh_token": "rotated-test-refresh", "token_type": "Bearer", "expires_in": 3600])
        }
        let vault = OneDriveTokenVault(record: OneDriveTokenRecord(clientID: Self.applicationID, accessToken: "expired-test-access", refreshToken: "test-refresh", expiresAt: .distantPast),
                                      configuration: configuration(), persistence: persistence.persistence)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await vault.token() } }
            var results: [String] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(tokens.count, 12)
        XCTAssertEqual(Set(tokens), ["new-test-access"])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(persistence.records.count, 1)
        XCTAssertEqual(persistence.records.first?.refreshToken, "rotated-test-refresh")
        XCTAssertTrue(persistence.deletedIDs.isEmpty)
    }

    func testRefreshClearsRevokedCredentialsButKeepsThemOnTransientFailure() async throws {
        for revoked in [true, false] {
            let persistence = OneDrivePersistenceProbe()
            OneDriveTestURLProtocol.responder = { _ in
                try Self.json(["error": revoked ? "invalid_grant" : "temporarily_unavailable", "error_description": "server response must never be exposed"], status: revoked ? 400 : 503)
            }
            let vault = OneDriveTokenVault(record: OneDriveTokenRecord(clientID: Self.applicationID, accessToken: "expired-test-access", refreshToken: "test-refresh", expiresAt: .distantPast),
                                          configuration: configuration(), persistence: persistence.persistence)
            do { _ = try await vault.token(); XCTFail("Expected failed refresh") }
            catch {
                XCTAssertEqual(error as? OneDriveError, revoked ? .needsLogin : .serviceUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("server response"))
            }
            XCTAssertEqual(persistence.deletedIDs, revoked ? [Self.applicationID] : [])
            XCTAssertTrue(persistence.records.isEmpty)
        }
    }

    func testDisconnectDuringRefreshCannotPersistOrReviveCredentials() async throws {
        let persistence = OneDrivePersistenceProbe()
        let vault = OneDriveTokenVault(record: OneDriveTokenRecord(clientID: Self.applicationID, accessToken: "expired-test-access", refreshToken: "test-refresh", expiresAt: .distantPast),
                                      configuration: configuration(), persistence: persistence.persistence)
        OneDriveTestURLProtocol.responder = { _ in
            vault.cancel()
            return try Self.json(["access_token": "late-test-access", "refresh_token": "late-test-refresh", "token_type": "Bearer", "expires_in": 3600])
        }
        do { _ = try await vault.token(); XCTFail("Disconnected refresh must not succeed") }
        catch {}
        try await vault.invalidate()
        XCTAssertTrue(persistence.records.isEmpty)
        XCTAssertEqual(persistence.deletedIDs, [Self.applicationID])
        do { _ = try await vault.token(); XCTFail("Disconnected vault must stay disconnected") }
        catch { XCTAssertEqual(error as? OneDriveError, .disconnected) }
    }
}
