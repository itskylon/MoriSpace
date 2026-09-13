#if targetEnvironment(simulator)
import XCTest
@testable import MoriPhotos

final class FileStationTests: XCTestCase {
    private func client() async throws -> SynologyClient {
        let client = try SynologyClient(address: FileStationFixture.credentials.address, service: .files, session: URLSession(configuration: FileStationFixture.configuration()))
        try await client.login(FileStationFixture.credentials, otp: "")
        return client
    }
    override func tearDown() { MockURLProtocol.responder = nil; super.tearDown() }

    func testFileSessionAndSpecialPathsUseJSONAndCookieWithoutPhotos() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responder = { request in
            let fields = FileStationFixture.fields(request)
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.url?.query)
            if fields["method"] == "login" { XCTAssertEqual(fields["session"], "FileStation") }
            return (200, try FileStationFixture.reply(request).2)
        }
        let client = try SynologyClient(address: "https://files.example.invalid:5001/photo", service: .files, session: URLSession(configuration: config))
        try await client.login(FileStationFixture.credentials, otp: "")
        let shares = try await client.files(path: nil, offset: 0)
        XCTAssertEqual(shares.items.first?.path, "/测试共享")
        let path = "/测试共享/a + b&c#%.json"
        let request = try await client.fileDownloadRequest(path: path)
        let fields = FileStationFixture.fields(request)
        XCTAssertEqual(request.url?.path, "/webapi/entry.cgi")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=file-test-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "file-test-token")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(fields["path"]!.utf8)), [path])
        XCTAssertEqual(fields["mode"], "\"download\"")
        for invalid in ["../a", "/share/../a", "/share//a", "/share/./a", "/"] { XCTAssertThrowsError(try NASFile.validatePath(invalid)) }
    }

    @MainActor
    func testDirectoryPaginationEmptyAndPermissionErrors() async throws {
        let client = try await client()
        let store = NASFileBrowserStore()
        await store.reset(client: client, path: "/测试共享", sort: .name, ascending: true)
        XCTAssertEqual(store.items.count, 100); XCTAssertTrue(store.hasMore)
        await store.loadMore(client: client, path: "/测试共享", sort: .name, ascending: true)
        XCTAssertEqual(store.items.count, 105); XCTAssertFalse(store.hasMore)
        XCTAssertEqual(Set(store.items.map(\.path)).count, 105)
        await store.reset(client: client, path: "/测试共享/空文件夹", sort: .name, ascending: true)
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(store.error)
        await store.reset(client: client, path: "/测试共享/无权限", sort: .name, ascending: true)
        XCTAssertTrue(store.error?.contains("权限") == true)
        XCTAssertFalse(store.error?.contains("IP") == true, "File Station 407 must not use Auth's blocked-IP message")
    }

    func testDownloadAcceptsArbitraryBytesAndRejectsErrorOrTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = URL(string: "https://files.example.invalid/webapi/entry.cgi")!
        let attached = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Disposition": "attachment; filename=result.json"])!
        let bytes = Data("{\"success\":false,\"error\":{\"code\":119}}".utf8)
        try bytes.write(to: file)
        XCTAssertNoThrow(try FileTransfer.validate(file: file, response: attached, expected: Int64(bytes.count)))
        XCTAssertThrowsError(try FileTransfer.validate(file: file, response: attached, expected: Int64(bytes.count + 1)))
        let errorResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        XCTAssertThrowsError(try FileTransfer.validate(file: file, response: errorResponse, expected: nil)) { XCTAssertTrue($0.localizedDescription.contains("重新连接")) }
        for bytes in [Data([0x50,0x4b,0x03,0x04,0xff,0x00]), Data(), Data("plain text 中文".utf8)] {
            try bytes.write(to: file)
            XCTAssertNoThrow(try FileTransfer.validate(file: file, response: attached, expected: Int64(bytes.count)))
        }
    }

    @MainActor
    func testDownloadQueuePersistsBytesNamesAndSupportsOfflineExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await client()
        let owner = NASService.accountID(FileStationFixture.credentials)
        let manager = NASDownloadManager(directory: root)
        manager.transferConfiguration = FileStationFixture.configuration
        let file = try await client.fileInfo(path: "/测试共享/说明 + 中文.txt")
        manager.enqueue(file, owner: owner, client: client)
        manager.enqueue(file, owner: owner, client: client)
        XCTAssertEqual(manager.records.count, 1, "Don't enqueue a duplicate active download")
        await wait { manager.records.first?.state == .completed || manager.records.first?.state == .failed }
        XCTAssertEqual(manager.records.first?.state, .completed, manager.records.first?.message ?? "")
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(try Data(contentsOf: manager.fileURL(record)), FileStationFixture.contents)
        XCTAssertEqual(manager.fileURL(record).lastPathComponent, "说明 + 中文.txt")
        let offline = NASDownloadManager(directory: root)
        XCTAssertEqual(offline.records.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: offline.fileURL(record)), FileStationFixture.contents)
        XCTAssertNotEqual(owner, NASService.accountID(NASCredentials(address: FileStationFixture.credentials.address, username: "other", password: "")))
        offline.remove(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: offline.fileURL(record).path))
    }

    @MainActor
    func testFailedDownloadCanRetryAndCancellationDoesNotPublishAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await client(), owner = "test-owner"
        let manager = NASDownloadManager(directory: root)
        MockURLProtocol.responder = { _ in (200, Data("{\"success\":false,\"error\":{\"code\":119}}".utf8)) }
        manager.transferConfiguration = { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]; return config }
        let file = try await client.fileInfo(path: "/测试共享/test.json")
        manager.enqueue(file, owner: owner, client: client)
        await wait { manager.records.first?.state == .failed }
        XCTAssertTrue(manager.records.first?.message?.contains("重新连接") == true)
        manager.transferConfiguration = FileStationFixture.configuration
        manager.retry(try XCTUnwrap(manager.records.first), client: client, owner: owner)
        await wait { manager.records.first?.state == .completed }
        XCTAssertEqual(manager.records.first?.state, .completed)
        manager.enqueue(file, owner: owner, client: client)
        let cancelled = try XCTUnwrap(manager.records.first)
        manager.cancel(cancelled.id)
        await wait { manager.records.first?.state == .cancelled }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(cancelled).path))
    }
    @MainActor
    func testUnreadableManifestIsNotOverwrittenAndCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("downloads.json")
        let damaged = Data("unreadable existing manifest".utf8)
        try damaged.write(to: manifest)
        let manager = NASDownloadManager(directory: root)
        let client = try await client()
        let file = try await client.fileInfo(path: "/测试共享/test.txt")
        manager.enqueue(file, owner: "test-owner", client: client)
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
        XCTAssertTrue(manager.records.isEmpty)
        try Data("[]".utf8).write(to: manifest)
        manager.reloadIfNeeded()
        XCTAssertNil(manager.error)
        manager.transferConfiguration = FileStationFixture.configuration
        manager.enqueue(file, owner: "test-owner", client: client)
        await wait { manager.records.first?.state == .completed }
        XCTAssertEqual(manager.records.first?.state, .completed)
    }
    @MainActor private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Timed out waiting for download state")
    }
}

#endif
