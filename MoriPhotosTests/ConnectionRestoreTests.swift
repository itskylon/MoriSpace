#if targetEnvironment(simulator)
import XCTest
@testable import MoriPhotos

private final class ConnectionTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions = Set<String>()
    private var attempts = 0
    private var failure: Int?
    var loginStarted: XCTestExpectation?
    var loginDelay: TimeInterval = 0
    var loginCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    func expire() { lock.lock(); sessions.removeAll(); lock.unlock() }
    func rejectLogin(_ code: Int?) { lock.lock(); failure = code; lock.unlock() }
    func reply(_ request: URLRequest, decodedFields: [String: String]? = nil) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let fields = decodedFields ?? FileStationFixture.fields(request)
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        var info = FileStationFixture.info
        info.merge(NASMonitorFixture.info) { _, new in new }
        for prefix in ["SYNO.Foto", "SYNO.FotoTeam"] {
            for suffix in ["Browse.Item", "Browse.Folder", "Thumbnail", "Download"] {
                info[prefix + "." + suffix] = ["path": "entry.cgi", "minVersion": 1, "maxVersion": 4, "requestFormat": "JSON"]
            }
        }
        var object: [String: Any] = ["success": true]
        if api == "SYNO.API.Info" { object["data"] = info }
        else if method == "login" {
            attempts += 1
            loginStarted?.fulfill()
            if loginDelay > 0 { Thread.sleep(forTimeInterval: loginDelay) }
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if let failure { object = ["success": false, "error": ["code": failure]] }
            else {
                let sid = (fields["session"] ?? "") + "-session-\(attempts)"
                sessions.insert(sid)
                object["data"] = ["sid": sid, "synotoken": "test-token"]
            }
        } else if method == "logout" {
            sessions.remove(fields["_sid"] ?? "")
        } else if !sessions.contains(fields["_sid"] ?? "") || request.value(forHTTPHeaderField: "Cookie") != "id=\(fields["_sid"] ?? "")" {
            object = ["success": false, "error": ["code": 119]]
        } else if let monitor = NASMonitorFixture.response(api: api) {
            object["data"] = monitor
        } else if api.hasPrefix("SYNO.FileStation") {
            object["data"] = ["shares": [FileStationFixture.file("测试共享", path: "/测试共享", folder: true)], "offset": 0, "total": 1]
        } else {
            object["data"] = ["list": api.hasSuffix("Item") ? [["id": 1, "filename": "sample.jpg"]] : []]
        }
        return (200, try JSONSerialization.data(withJSONObject: object))
    }
}

private final class ConnectionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let server: ConnectionTestServer
    private let shouldBlock: ([String: String]) -> Bool
    private var blocked = Set<ObjectIdentifier>()
    private var stoppedCount = 0
    private var logoutCount = 0
    let started: XCTestExpectation
    var stopped: XCTestExpectation?
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stoppedCount }
    var logouts: Int { lock.lock(); defer { lock.unlock() }; return logoutCount }
    init(server: ConnectionTestServer, started: XCTestExpectation, shouldBlock: @escaping ([String: String]) -> Bool) {
        self.server = server; self.started = started; self.shouldBlock = shouldBlock
    }
    func load(_ loader: MockURLProtocol, decodedFields: [String: String]? = nil) {
        let fields = decodedFields ?? FileStationFixture.fields(loader.request)
        lock.lock()
        if fields["method"] == "logout" { logoutCount += 1 }
        let blocks = shouldBlock(fields)
        if blocks { blocked.insert(ObjectIdentifier(loader)) }
        lock.unlock()
        if blocks { started.fulfill(); return }
        do {
            let (status, data) = try server.reply(loader.request, decodedFields: fields)
            loader.respond(status: status, data: data)
        } catch { loader.client?.urlProtocol(loader, didFailWithError: error) }
    }
    func stop(_ loader: MockURLProtocol) {
        lock.lock()
        let held = blocked.remove(ObjectIdentifier(loader)) != nil
        if held { stoppedCount += 1 }
        lock.unlock()
        if held { stopped?.fulfill() }
    }
    func install() {
        MockURLProtocol.asyncLoader = { [self] in load($0) }
        MockURLProtocol.stopped = { [self] in stop($0) }
    }
}

@MainActor
private final class MemoryConnection {
    var data: Data?
    init(_ record: SavedNASConnection?) throws { data = try record.map { try JSONEncoder().encode($0) } }
    var persistence: ConnectionPersistence {
        ConnectionPersistence(load: { try self.data.map(SavedNASConnection.decode) }, save: { self.data = try JSONEncoder().encode($0) }, delete: { self.data = nil })
    }
    var record: SavedNASConnection? { try? data.map(SavedNASConnection.decode) }
}

@MainActor
final class ConnectionRestoreTests: XCTestCase {
    private let account = NASCredentials(address: "https://nas.example.invalid", username: "test-user", password: "test-password")
    private func state(_ storage: MemoryConnection, timeout: Duration = .seconds(30)) -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RestoreTest-" + UUID().uuidString)
        return AppState(persistence: storage.persistence, makeClient: { account, service in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
            return try SynologyClient(address: account.address, service: service, session: URLSession(configuration: config))
        }, downloads: NASDownloadManager(directory: folder), connectionTimeout: timeout)
    }
    private func server() -> ConnectionTestServer {
        let server = ConnectionTestServer()
        MockURLProtocol.responder = { try server.reply($0) }
        return server
    }
    override func tearDown() { MockURLProtocol.responder = nil; MockURLProtocol.asyncLoader = nil; MockURLProtocol.stopped = nil; super.tearDown() }

    func testLegacyCredentialsAndRestartReuseBothSessionsWithoutLogin() async throws {
        let server = server()
        let storage = try MemoryConnection(nil)
        storage.data = try JSONEncoder().encode(account)
        let first = state(storage)
        await first.restoreConnection(service: .photos)
        await first.restoreConnection(service: .files)
        XCTAssertNotNil(first.client); XCTAssertNotNil(first.fileClient)
        XCTAssertEqual(server.loginCount, 2)
        XCTAssertEqual(storage.record?.sessions.count, 2)
        let restarted = state(storage)
        await restarted.restoreConnection(service: .photos)
        await restarted.restoreConnection(service: .files)
        let photos = try XCTUnwrap(restarted.client)
        let files = try XCTUnwrap(restarted.fileClient)
        let items = try await photos.photos(space: .personal, offset: 0)
        let shares = try await files.files(path: nil, offset: 0)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(shares.items.count, 1)
        await restarted.restoreConnection(service: .photos)
        await restarted.restoreConnection(service: .files)
        XCTAssertEqual(server.loginCount, 2, "Switching services or restarting must reuse valid sessions")
    }

    func testMonitorSessionRestoresRenewsAndDisconnectsWithOtherServices() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let first = state(storage)
        await first.restoreConnection(service: .photos)
        await first.restoreConnection(service: .files)
        await first.restoreConnection(service: .monitor)
        XCTAssertEqual(server.loginCount, 3)
        XCTAssertEqual(storage.record?.sessions.count, 3)
        let restarted = state(storage)
        await restarted.restoreConnection(service: .monitor)
        let monitor = try XCTUnwrap(restarted.monitorClient)
        let before = await monitor.monitorSnapshot()
        XCTAssertEqual(before.resources?.cpu, 18)
        XCTAssertEqual(server.loginCount, 3)
        server.expire()
        let after = await monitor.monitorSnapshot()
        XCTAssertTrue(after.issues.isEmpty)
        XCTAssertEqual(server.loginCount, 4, "Three concurrent reads must share one renewal")
        await restarted.disconnect()
        XCTAssertNil(restarted.monitorClient)
        XCTAssertTrue(storage.record?.sessions.isEmpty == true)
        let disconnected = state(storage)
        await disconnected.restoreConnection(service: .monitor)
        XCTAssertNil(disconnected.monitorClient)
        XCTAssertEqual(server.loginCount, 4)
    }

    func testConcurrentRestoreAndExpiredReadsRenewOnlyOnce() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        async let first: Void = app.restoreConnection(service: .photos)
        async let second: Void = app.restoreConnection(service: .photos)
        _ = await (first, second)
        XCTAssertEqual(server.loginCount, 1)
        server.expire()
        let client = try XCTUnwrap(app.client)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { try await client.photos(space: .personal, offset: 0).count } }
            for try await count in group { XCTAssertEqual(count, 1) }
        }
        XCTAssertEqual(server.loginCount, 2, "Parallel image/list requests must share a renewal")
        let restarted = state(storage)
        await restarted.restoreConnection(service: .photos)
        _ = try await XCTUnwrap(restarted.client).photos(space: .personal, offset: 0)
        XCTAssertEqual(server.loginCount, 2, "Renewed session must be persisted")
    }

    func testExpiredSessionAfterRelaunchRecoversOnFirstGalleryLoad() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let first = state(storage)
        await first.restoreConnection(service: .photos)
        server.expire()
        let restarted = state(storage)
        await restarted.restoreConnection(service: .photos)
        let browser = NASBrowserStore()
        await browser.reset(client: try XCTUnwrap(restarted.client), space: .personal, folder: nil)
        XCTAssertNil(browser.error); XCTAssertEqual(browser.photos.count, 1)
        XCTAssertEqual(server.loginCount, 2)
    }

    func testChangingAccountDiscardsOtherServiceSession() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        await app.restoreConnection(service: .photos)
        await app.restoreConnection(service: .files)
        let other = NASCredentials(address: account.address, username: "another-user", password: "other-password")
        app.credentials = other
        let connected = await app.connect(service: .photos)
        XCTAssertTrue(connected); XCTAssertNil(app.fileClient)
        XCTAssertEqual(storage.record?.credentials, other)
        XCTAssertEqual(storage.record?.sessions.count, 1)
        await app.restoreConnection(service: .files)
        XCTAssertNotNil(app.fileClient)
        XCTAssertEqual(app.fileAccountID, NASService.accountID(other))
        XCTAssertEqual(server.loginCount, 4)
    }

    func testBadPasswordOrOTPStopsAutomaticAttemptsAcrossServicesAndRestarts() async throws {
        for code in [400, 403, 407] {
            let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
            server.rejectLogin(code)
            let app = state(storage)
            async let photos: Void = app.restoreConnection(service: .photos)
            async let files: Void = app.restoreConnection(service: .files)
            _ = await (photos, files)
            await app.restoreConnection(service: .photos, retry: true)
            let restarted = state(storage)
            await restarted.restoreConnection(service: .files)
            XCTAssertEqual(server.loginCount, 1, "Do not loop authentication failures or request another service's login")
            XCTAssertTrue(storage.record?.requiresLogin == true)
            XCTAssertNil(app.client); XCTAssertNil(app.fileClient)
        }
    }

    func testExpiredSessionBadPasswordDoesNotLoopOrDiscardCredentials() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        await app.restoreConnection(service: .files)
        let client = try XCTUnwrap(app.fileClient)
        server.expire(); server.rejectLogin(400)
        for _ in 0..<3 {
            do { _ = try await client.files(path: nil, offset: 0); XCTFail("Expected expired authentication") } catch {}
        }
        XCTAssertEqual(server.loginCount, 2)
        XCTAssertEqual(storage.record?.credentials, account)
        XCTAssertTrue(storage.record?.requiresLogin == true)
    }

    func testManualDisconnectPersistsAndReconnectResumesOtherService() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        await app.restoreConnection(service: .photos)
        await app.disconnect()
        let restarted = state(storage)
        await restarted.restoreConnection(service: .photos)
        await restarted.restoreConnection(service: .files)
        XCTAssertEqual(server.loginCount, 1); XCTAssertNil(restarted.client)
        let connected = await restarted.connect(service: .photos)
        XCTAssertTrue(connected)
        await restarted.restoreConnection(service: .files)
        XCTAssertNotNil(restarted.fileClient); XCTAssertEqual(server.loginCount, 3)
        await restarted.forget()
        XCTAssertNil(storage.data)
        await restarted.restoreConnection(service: .photos)
        XCTAssertNil(restarted.client); XCTAssertEqual(server.loginCount, 3)
    }

    func testNotRememberedLoginOnlyRestoresOtherServiceForCurrentRun() async throws {
        let server = server(), storage = try MemoryConnection(nil)
        let app = state(storage)
        app.credentials = account; app.remember = false
        let connected = await app.connect(service: .photos)
        XCTAssertTrue(connected)
        await app.restoreConnection(service: .files)
        XCTAssertNotNil(app.fileClient); XCTAssertNil(storage.data)
        let restarted = state(storage)
        await restarted.restoreConnection(service: .photos)
        XCTAssertNil(restarted.client); XCTAssertEqual(server.loginCount, 2)
    }

    func testDisconnectDuringRestoreCannotPublishOrSaveLateSession() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let started = expectation(description: "Authentication started")
        server.loginStarted = started; server.loginDelay = 0.2
        let app = state(storage)
        let restore = Task { await app.restoreConnection(service: .photos) }
        await fulfillment(of: [started], timeout: 3)
        await app.disconnect()
        await restore.value
        XCTAssertNil(app.client)
        XCTAssertTrue(storage.record?.sessions.isEmpty == true)
        XCTAssertTrue(storage.record?.automatic == false)
    }

    func testUnavailableNetworkDoesNotLoopAndExplicitRetryRecovers() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        MockURLProtocol.responder = { _ in throw URLError(.notConnectedToInternet) }
        let app = state(storage)
        await app.restoreConnection(service: .photos)
        XCTAssertNil(app.client); XCTAssertNotNil(app.restoreErrors[.photos])
        XCTAssertFalse(storage.record?.requiresLogin == true)
        MockURLProtocol.responder = { try server.reply($0) }
        await app.restoreConnection(service: .photos)
        XCTAssertEqual(server.loginCount, 0)
        await app.restoreConnection(service: .photos, retry: true)
        XCTAssertNotNil(app.client); XCTAssertEqual(server.loginCount, 1)
    }

    func testCancelStalledManualLoginPreservesSavedAndUsableSession() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        await app.restoreConnection(service: .photos)
        let original = try XCTUnwrap(app.client), before = storage.data
        let started = expectation(description: "Manual discovery stalled")
        let stopped = expectation(description: "URLSession request cancelled")
        let gate = ConnectionRequestGate(server: server, started: started) { $0["api"] == "SYNO.API.Info" }
        gate.stopped = stopped; gate.install()
        let finished = expectation(description: "Manual connection returned")
        let task = Task { let result = await app.connect(); XCTAssertFalse(result); finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(app.connecting)
        XCTAssertEqual(app.connectionPhase?.title, NASConnectionPhase.reachingServer.title)
        app.cancelConnection()
        XCTAssertFalse(app.connecting); XCTAssertNil(app.connectionPhase); XCTAssertNil(app.error)
        XCTAssertTrue(app.client === original); XCTAssertEqual(storage.data, before)
        await fulfillment(of: [stopped, finished], timeout: 2)
        await task.value
        XCTAssertFalse(storage.record?.requiresLogin == true)
        XCTAssertEqual(server.loginCount, 1, "The cancelled discovery must not submit another password")
    }

    func testDeadlineIncludesWaitingForAutomaticRestore() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage, timeout: .milliseconds(120)), before = storage.data
        let started = expectation(description: "Automatic request stalled")
        let stopped = expectation(description: "Automatic request cancelled during cleanup")
        let gate = ConnectionRequestGate(server: server, started: started) { $0["api"] == "SYNO.API.Info" }
        gate.stopped = stopped; gate.install()
        let restore = Task { await app.restoreConnection(service: .photos) }
        await fulfillment(of: [started], timeout: 2)
        let finished = expectation(description: "Queued manual request timed out")
        let task = Task { let result = await app.connect(); XCTAssertFalse(result); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(app.connecting); XCTAssertNil(app.connectionPhase)
        XCTAssertTrue(app.error?.contains("等待已有连接未完成") == true)
        XCTAssertTrue(app.error?.contains("超时") == true)
        XCTAssertEqual(storage.data, before); XCTAssertEqual(server.loginCount, 0)
        await app.disconnect()
        await fulfillment(of: [stopped], timeout: 2)
        await restore.value; await task.value
    }

    func testCancelOldAttemptThenRetryCannotClearOrOverwriteNewAttempt() async throws {
        let server = server(), storage = try MemoryConnection(nil)
        let app = state(storage); app.credentials = account
        let started = expectation(description: "Old login stalled")
        let stopped = expectation(description: "Old login cancelled")
        let gate = ConnectionRequestGate(server: server, started: started) { $0["method"] == "login" }
        gate.stopped = stopped; gate.install()
        let old = Task { await app.connect() }
        await fulfillment(of: [started], timeout: 2)
        app.cancelConnection()
        MockURLProtocol.asyncLoader = nil
        let replacement = NASCredentials(address: account.address, username: "replacement-user", password: "replacement-password")
        app.credentials = replacement
        let result = await app.connect()
        XCTAssertTrue(result)
        let installed = try XCTUnwrap(app.client)
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(app.client === installed); XCTAssertEqual(app.activeCredentials, replacement)
        XCTAssertEqual(storage.record?.credentials, replacement)
        XCTAssertFalse(storage.record?.requiresLogin == true)
        XCTAssertFalse(app.connecting); XCTAssertNil(app.connectionPhase); XCTAssertNil(app.error)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(server.loginCount, 1)
    }

    func testDisconnectOrForgetDuringManualLoginDoesNotPersistLateResult() async throws {
        for forgetting in [false, true] {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage)
        let started = expectation(description: "Service check stalled after password acceptance")
        let stopped = expectation(description: "Service check cancelled")
        let gate = ConnectionRequestGate(server: server, started: started) {
            $0["api"] == "SYNO.API.Info" && $0["_sid"] != nil
        }
        gate.stopped = stopped; gate.install()
        let finished = expectation(description: "Cancelled login returned")
        let task = Task { let result = await app.connect(); XCTAssertFalse(result); finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(app.connectionPhase?.title, NASConnectionPhase.checkingService.title)
        if forgetting { await app.forget() } else { await app.disconnect() }
        await fulfillment(of: [stopped, finished], timeout: 2)
        await task.value
        XCTAssertNil(app.client); XCTAssertFalse(app.connecting)
        if forgetting { XCTAssertNil(storage.data); XCTAssertNil(app.activeCredentials) }
        else {
            XCTAssertTrue(storage.record?.sessions.isEmpty == true)
            XCTAssertTrue(storage.record?.automatic == false)
        }
        XCTAssertFalse(storage.record?.requiresLogin == true)
        }
    }

    func testServiceCheckFailureDoesNotWaitForLogout() async throws {
        let server = server(), storage = try MemoryConnection(nil)
        let app = state(storage); app.credentials = account
        let logout = expectation(description: "No cleanup network logout")
        logout.isInverted = true
        let gate = ConnectionRequestGate(server: server, started: logout) { $0["method"] == "logout" }
        MockURLProtocol.asyncLoader = { loader in
            let fields = FileStationFixture.fields(loader.request)
            if fields["api"] == "SYNO.API.Info", fields["_sid"] != nil {
                loader.client?.urlProtocol(loader, didFailWithError: URLError(.secureConnectionFailed))
            } else { gate.load(loader, decodedFields: fields) }
        }
        let result = await app.connect()
        XCTAssertFalse(result); XCTAssertFalse(app.connecting)
        XCTAssertTrue(app.error?.contains("检查服务权限未完成") == true)
        XCTAssertTrue(app.error?.contains("TLS") == true)
        XCTAssertNil(storage.data); XCTAssertNil(app.client)
        await fulfillment(of: [logout], timeout: 0.15)
        XCTAssertEqual(gate.logouts, 0)
    }

    func testCancelledAuthenticationRejectionDoesNotMarkSavedAccountAsInvalid() async throws {
        let server = server(), storage = try MemoryConnection(SavedNASConnection(credentials: account))
        let app = state(storage), before = storage.data
        let started = expectation(description: "Rejecting authentication entered")
        server.rejectLogin(400); server.loginStarted = started; server.loginDelay = 0.2
        let finished = expectation(description: "Cancelled rejection returned")
        let task = Task { let result = await app.connect(); XCTAssertFalse(result); finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        app.cancelConnection()
        await fulfillment(of: [finished], timeout: 2)
        await task.value
        XCTAssertFalse(app.connecting); XCTAssertNil(app.error)
        XCTAssertEqual(storage.data, before)
        XCTAssertFalse(storage.record?.requiresLogin == true)
    }

    func testStalledAuthenticationDeadlineCancelsTransportAndAllowsRetry() async throws {
        let server = server(), storage = try MemoryConnection(nil)
        let app = state(storage, timeout: .milliseconds(600)); app.credentials = account
        let started = expectation(description: "Authentication transport stalled")
        let stopped = expectation(description: "Deadline cancelled transport")
        let gate = ConnectionRequestGate(server: server, started: started) { $0["method"] == "login" }
        gate.stopped = stopped; gate.install()
        let task = Task { await app.connect() }
        await fulfillment(of: [started, stopped], timeout: 2)
        let result = await task.value
        XCTAssertFalse(result); XCTAssertFalse(app.connecting)
        XCTAssertTrue(app.error?.contains("验证账号失败") == true)
        XCTAssertTrue(app.error?.contains("超时") == true)
        XCTAssertNil(storage.data); XCTAssertNil(app.client)
        MockURLProtocol.asyncLoader = nil
        let retried = await app.connect()
        XCTAssertTrue(retried); XCTAssertNotNil(app.client); XCTAssertNil(app.error)
    }

}
#endif
