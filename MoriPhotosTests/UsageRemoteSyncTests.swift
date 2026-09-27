import XCTest
import Security
@testable import MoriPhotos

final class UsageRemoteSyncTests: XCTestCase {
    private let token = String(repeating: "a1", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func tearDown() {
        UsageRemoteTestProtocol.loader = nil
        UsageRemoteTestProtocol.stopped = nil
        super.tearDown()
    }
    private func configuration(_ address: String = "https://usage.example.invalid/mori-usage/") throws -> UsageRemoteConfiguration {
        try UsageRemoteConfiguration(baseURL: address, readToken: token)
    }
    private func sessionSettings() -> URLSessionConfiguration {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UsageRemoteTestProtocol.self]
        return settings
    }
    private func snapshot() -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(fetchedAt: now.addingTimeInterval(-60), validUntil: now.addingTimeInterval(840), status: .ready,
                            windows: [UsageWidgetWindow(id: "codex:primary", label: "Codex · 5 小时", usedPercent: 32,
                                                        windowMinutes: 300, resetsAt: now.addingTimeInterval(1200))])
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testConfigurationPreservesSubpathAndRejectsUnsafeAddresses() throws {
        let value = try configuration()
        XCTAssertEqual(value.baseURL, "https://usage.example.invalid/mori-usage")
        XCTAssertEqual(value.endpointURL.absoluteString, "https://usage.example.invalid/mori-usage/v1/usage")
        XCTAssertEqual(try configuration("https://usage.example.invalid/").endpointURL.absoluteString, "https://usage.example.invalid/v1/usage")
        for address in ["http://usage.example.invalid", "https://user:password@usage.example.invalid", "https://@usage.example.invalid",
                        "https://usage.example.invalid?token=x", "https://usage.example.invalid#section", "https://usage.example.invalid?",
                        "https://usage.example.invalid/a/../b", "https://usage.example.invalid/%2E%2E/b", "https://usage.example.invalid/a%2fb",
                        "https://usage.example.invalid//b", "https://usage.example.invalid:0", "https://usage.example.invalid:99999",
                        "https://", "//usage.example.invalid", " https://usage.example.invalid"] {
            XCTAssertThrowsError(try configuration(address), address)
        }
    }

    func testConfigurationOnlyAcceptsVersionURLAndHexReadToken() throws {
        let value = try configuration()
        XCTAssertEqual(try UsageRemoteConfiguration.decode(value.encoded()), value)
        let original: [String: Any] = ["version": 1, "baseURL": value.baseURL, "readToken": token]
        for extra in ["writeToken", "accessToken", "accountId"] {
            var invalid = original; invalid[extra] = "unexpected-field"
            XCTAssertThrowsError(try UsageRemoteConfiguration.decode(json(invalid)))
        }
        for invalidToken in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "z", count: 64), token + "\n"] {
            XCTAssertThrowsError(try UsageRemoteConfiguration(baseURL: value.baseURL, readToken: invalidToken))
        }
        var invalid = original; invalid["version"] = 2
        XCTAssertThrowsError(try UsageRemoteConfiguration.decode(json(invalid)))
        XCTAssertThrowsError(try UsageRemoteConfiguration.decode(Data(repeating: 32, count: UsageRemoteConfiguration.maximumFileSize + 1)))
        XCTAssertThrowsError(try UsageRemoteConfiguration.decode(Data("[]".utf8)))
        XCTAssertFalse(String(describing: value).contains(token))
        XCTAssertFalse(String(reflecting: value).contains(token))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any]).keys), ["version", "baseURL", "readToken"])
    }

    func testKeychainUsesExplicitGroupDeviceOnlyProtectionAndIndependentService() throws {
        let probe = UsageKeychainProbe()
        let store = UsageRemoteKeychainStore(accessGroup: "TEAMID.dev.kylon.MoriPhotos.usage", operations: probe.operations)
        let value = try configuration()
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        let added = try XCTUnwrap(probe.added)
        XCTAssertEqual(added[kSecAttrAccessGroup as String] as? String, "TEAMID.dev.kylon.MoriPhotos.usage")
        XCTAssertEqual(added[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(added[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(added[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(added[kSecAttrService as String] as? String, "dev.kylon.MoriPhotos.usage.remote")
        XCTAssertEqual(try UsageRemoteConfiguration.decode(XCTUnwrap(added[kSecValueData as String] as? Data)), value)
        try store.save(try configuration("https://usage.example.invalid/new-base"))
        XCTAssertEqual(probe.updated?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testKeychainNeverFallsBackWithoutAResolvedAccessGroup() throws {
        for group in [nil, "", "$(AppIdentifierPrefix)dev.kylon.usage", "group with spaces"] as [String?] {
            let probe = UsageKeychainProbe()
            let store = UsageRemoteKeychainStore(accessGroup: group, operations: probe.operations)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(configuration()))
            XCTAssertThrowsError(try store.delete())
            XCTAssertEqual(probe.calls, 0)
        }
    }

    func testFetchSendsOnlyBearerToHTTPSSubpathAndReturnsUnchangedSnapshot() async throws {
        let expected = snapshot(), account = try configuration()
        let payload = try expected.encoded(now: now)
        UsageRemoteTestProtocol.loader = { protocolInstance in
            let request = protocolInstance.request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, account.endpointURL)
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + account.readToken)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            protocolInstance.respond(data: payload)
        }
        let result = try await UsageRemoteClient.fetch(configuration: account, sessionConfiguration: sessionSettings(), now: { self.now })
        XCTAssertEqual(result, expected)
    }

    func testHTTPStatusMimeAndResponseOriginMustMatch() async throws {
        let data = try snapshot().encoded(now: now)
        let cases: [(Int, String, URL?)] = [(401, "application/json", nil), (302, "application/json", nil),
                                           (200, "text/html", nil), (200, "application/json", URL(string: "https://other.example.invalid/v1/usage")),
                                           (200, "application/json", URL(string: "http://usage.example.invalid/mori-usage/v1/usage"))]
        for (status, mime, url) in cases {
            UsageRemoteTestProtocol.loader = { $0.respond(status: status, headers: ["Content-Type": mime], data: data, url: url) }
            do {
                _ = try await UsageRemoteClient.fetch(configuration: configuration(), sessionConfiguration: sessionSettings(), now: { self.now })
                XCTFail("Unexpectedly accepted response status, MIME type, or origin")
            } catch {}
        }
    }

    func testOversizedAndInvalidSnapshotsAreRejectedWithoutTrustingContentLength() async throws {
        let excessive = Data(repeating: 32, count: UsageRemoteClient.maximumResponseBytes + 1)
        let future = UsageWidgetSnapshot(fetchedAt: now.addingTimeInterval(10), validUntil: now.addingTimeInterval(910), status: .ready, windows: snapshot().windows)
        for data in [excessive, Data("not-json".utf8), try future.encoded(now: now.addingTimeInterval(10))] {
            UsageRemoteTestProtocol.loader = { $0.respond(data: data) }
            do {
                _ = try await UsageRemoteClient.fetch(configuration: configuration(), sessionConfiguration: sessionSettings(), now: { self.now })
                XCTFail("Unexpectedly accepted oversized or invalid snapshot")
            } catch {}
        }
        UsageRemoteTestProtocol.loader = { $0.respond(headers: ["Content-Type": "application/json", "Content-Length": "65537"], data: Data()) }
        do {
            _ = try await UsageRemoteClient.fetch(configuration: configuration(), sessionConfiguration: sessionSettings(), now: { self.now })
            XCTFail("Unexpectedly accepted oversized declared length")
        } catch {}
    }

    func testCancellationStopsPendingURLProtocol() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        UsageRemoteTestProtocol.loader = { _ in started.fulfill() }
        UsageRemoteTestProtocol.stopped = { stopped.fulfill() }
        let account = try configuration(), settings = sessionSettings()
        let operation = Task { try await UsageRemoteClient.fetch(configuration: account, sessionConfiguration: settings) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation unexpectedly succeeded") } catch {}
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testRedirectAndExtraAuthenticationAreRejected() throws {
        let delegate = UsageRemoteRequestDelegate(), account = try configuration()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: account.endpointURL)
        let redirect = HTTPURLResponse(url: account.endpointURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://other.example.invalid"] )!
        var redirected = true
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: URL(string: "https://other.example.invalid")!)) { redirected = $0 != nil }
        XCTAssertFalse(redirected)
        let space = URLProtectionSpace(host: "usage.example.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: UsageChallengeSender())
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(session, task: task, didReceive: challenge) { result, credential in
            disposition = result; XCTAssertNil(credential)
        }
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
    }
}

private final class UsageRemoteTestProtocol: URLProtocol {
    static var loader: ((UsageRemoteTestProtocol) -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.loader?(self) }
    override func stopLoading() { Self.stopped?() }
    func respond(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"], data: Data, url: URL? = nil) {
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class UsageKeychainProbe {
    var calls = 0
    var added: [String: Any]?
    var updated: [String: Any]?
    var data: Data?
    var operations: UsageRemoteKeychainOperations {
        UsageRemoteKeychainOperations(add: { item in
            self.calls += 1; self.added = item; self.data = item[kSecValueData as String] as? Data; return errSecSuccess
        }, update: { _, changes in
            self.calls += 1
            guard self.data != nil else { return errSecItemNotFound }
            self.updated = changes; self.data = changes[kSecValueData as String] as? Data; return errSecSuccess
        }, copy: { _ in
            self.calls += 1
            return self.data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }, delete: { _ in
            self.calls += 1; self.data = nil; return errSecSuccess
        })
    }
}

private final class UsageChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
