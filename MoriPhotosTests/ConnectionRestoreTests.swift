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
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let fields = FileStationFixture.fields(request)
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
    private func state(_ storage: MemoryConnection) -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RestoreTest-" + UUID().uuidString)
        return AppState(persistence: storage.persistence, makeClient: { account, service in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
            return try SynologyClient(address: account.address, service: service, session: URLSession(configuration: config))
        }, downloads: NASDownloadManager(directory: folder))
    }
    private func server() -> ConnectionTestServer {
        let server = ConnectionTestServer()
        MockURLProtocol.responder = { try server.reply($0) }
        return server
    }
    override func tearDown() { MockURLProtocol.responder = nil; super.tearDown() }

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
}
#endif
