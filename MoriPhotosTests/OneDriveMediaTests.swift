import XCTest
@testable import MoriPhotos

@MainActor
final class OneDriveMediaTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveMediaTestProtocol.self]
        // The content layer must strip even accidentally inherited Graph headers.
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer synthetic-only", "Cookie": "synthetic-only=1"]
        return configuration
    }
    private func url(_ path: String) -> URL { URL(string: "https://content.example.invalid/" + path + "?signature=synthetic-only")! }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OneDriveMediaTest-" + UUID().uuidString) }
    private func item(_ id: String = "complete", name: String = "sample.txt", tag: String = "version-one") -> OneDriveItem {
        OneDriveItem(id: id, name: name, size: 12, mimeType: "text/plain", eTag: tag, driveID: "synthetic-drive")
    }
    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for media state")
    }

    func testContentURLPolicyAndSafeLocalFilenames() throws {
        for value in ["http://content.example.invalid/file", "file:///private/file", "https://name:password@content.example.invalid/file",
                      "https://content.example.invalid/file#fragment", "https://content.example.invalid:8443/file"] {
            XCTAssertThrowsError(try OneDriveContentPolicy.request(for: URL(string: value)!))
        }
        let request = try OneDriveContentPolicy.request(for: url("file"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(OneDriveMediaIdentity.safeName("../../outside.txt"), "outside.txt")
        XCTAssertEqual(OneDriveMediaIdentity.safeName("folder\\outside.txt"), "outside.txt")
        XCTAssertEqual(OneDriveMediaIdentity.safeName("a:b\u{0000}.txt"), "a_b_.txt")
        XCTAssertEqual(OneDriveMediaIdentity.safeName(".."), "download")
        let longName = OneDriveMediaIdentity.safeName(String(repeating: "照片", count: 100) + ".jpeg")
        XCTAssertLessThanOrEqual(longName.utf8.count, 200); XCTAssertTrue(longName.hasSuffix(".jpeg"))
    }

    func testStreamingContentHasNoCredentialsAndValidatesExpectedSize() async throws {
        let transfer = OneDriveContentTransfer(configuration: configuration(), expectedSize: 12) { _, _ in }
        let file = try await transfer.run(url: url("complete"))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("hello world\n".utf8))
        for path in ["wrong-length", "partial"] {
            let transfer = OneDriveContentTransfer(configuration: configuration(), expectedSize: 12) { _, _ in }
            do { let file = try await transfer.run(url: url(path)); try? FileManager.default.removeItem(at: file); XCTFail("Incomplete download accepted") }
            catch { XCTAssertTrue(error is OneDriveMediaError) }
        }
    }

    func testSizeLimitAlsoCatchesChunkedUnknownLengthResponses() async throws {
        let transfer = OneDriveContentTransfer(configuration: configuration(), expectedSize: nil, byteLimit: 8) { _, _ in }
        do { _ = try await transfer.run(url: url("chunked")); XCTFail("Unbounded content accepted") }
        catch { XCTAssertEqual(error.localizedDescription, OneDriveMediaError.tooLarge.localizedDescription) }
        let tooLarge = OneDriveContentTransfer(configuration: configuration(), expectedSize: 31_000_000, byteLimit: OneDrivePreviewModel.limit) { _, _ in }
        do { _ = try await tooLarge.run(url: url("never-requested")); XCTFail("Oversized preview accepted") }
        catch { XCTAssertEqual(error.localizedDescription, OneDriveMediaError.tooLarge.localizedDescription) }
    }

    func testCancellationBeforeAndDuringTransferCleansTemporaryFiles() async throws {
        let preCancelled = OneDriveContentTransfer(configuration: configuration(), expectedSize: nil) { _, _ in }
        preCancelled.cancel()
        do { _ = try await preCancelled.run(url: url("never-requested")); XCTFail("Precancelled transfer started") }
        catch { XCTAssertTrue(error is CancellationError) }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("MoriOneDrive-") })
        let transfer = OneDriveContentTransfer(configuration: configuration(), expectedSize: nil) { _, _ in }
        let url = url("hang")
        let task = Task { try await transfer.run(url: url) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("MoriOneDrive-") })
        XCTAssertEqual(after, before)
    }

    func testDownloadsPersistIsolateAccountsAndNeverStoreSignedLinks() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = OneDriveMediaStore(directory: directory); store.transferConfiguration = { self.configuration() }
        let file = item(name: "../sample.txt")
        let client = OneDriveMediaTestClient(file: file)
        let first = store.enqueue(item: file, client: client, accountID: "account-a")
        let second = store.enqueue(item: file, client: client, accountID: "account-b")
        try await waitFor { store.records.filter { $0.state == .completed }.count == 2 }
        XCTAssertNotEqual(first, second)
        let firstURL = try XCTUnwrap(store.localURL(for: file, accountID: "account-a"))
        let secondURL = try XCTUnwrap(store.localURL(for: file, accountID: "account-b"))
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.lastPathComponent, "sample.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL).count, 12)
        XCTAssertNil(store.localURL(for: item(tag: "replacement"), accountID: "account-a"))
        let reloaded = OneDriveMediaStore(directory: directory)
        XCTAssertEqual(reloaded.records(for: "account-a").count, 1)
        XCTAssertEqual(reloaded.localURL(for: file, accountID: "account-a"), firstURL)
        let manifest = try String(contentsOf: directory.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("signature")); XCTAssertFalse(manifest.contains("synthetic-only")); XCTAssertFalse(manifest.contains("account-a"))
        let firstRecord = try XCTUnwrap(reloaded.records(for: "account-a").first)
        reloaded.remove(record: firstRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testDisconnectCancelsActiveAndQueuedDownloadsForOnlyThatAccount() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = OneDriveMediaStore(directory: directory); store.transferConfiguration = { self.configuration() }
        for number in 0..<3 {
            let file = item("hang-\(number)")
            store.enqueue(item: file, client: OneDriveMediaTestClient(file: file), accountID: "account-a")
        }
        try await waitFor { store.records.filter { $0.state == .downloading }.count == 2 }
        store.cancel(accountID: "account-a")
        XCTAssertEqual(store.records(for: "account-a").filter { $0.state == .cancelled }.count, 3)
        XCTAssertFalse(store.records.contains { $0.active })
        let file = item()
        store.enqueue(item: file, client: OneDriveMediaTestClient(file: file), accountID: "account-b")
        try await waitFor { store.records(for: "account-b").first?.state == .completed }
        XCTAssertNotNil(store.localURL(for: file, accountID: "account-b"))
        XCTAssertTrue(store.records(for: "account-a").allSatisfy { $0.state == .cancelled })
    }

    func testPreviewOwnsAndRemovesOnlyItsTemporaryFile() async throws {
        let model = OneDrivePreviewModel()
        let file = item()
        await model.load(item: file, client: OneDriveMediaTestClient(file: file), accountID: UUID().uuidString, configuration: configuration())
        let preview = try XCTUnwrap(model.url, model.error ?? "No preview URL")
        XCTAssertEqual(try Data(contentsOf: preview).count, 12)
        model.stop()
        XCTAssertNil(model.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.deletingLastPathComponent().path))
    }

    func testPlaybackIdentityDoesNotDependOnExpiringURLOrFilename() {
        let original = item()
        let renamed = item(name: "renamed.txt")
        XCTAssertEqual(OneDriveMediaIdentity.key(item: original, accountID: "account-a"), OneDriveMediaIdentity.key(item: renamed, accountID: "account-a"))
        XCTAssertNotEqual(OneDriveMediaIdentity.key(item: original, accountID: "account-a"), OneDriveMediaIdentity.key(item: item(tag: "replacement"), accountID: "account-a"))
        XCTAssertNotEqual(OneDriveMediaIdentity.key(item: original, accountID: "account-a"), OneDriveMediaIdentity.key(item: original, accountID: "account-b"))
    }
}

private actor OneDriveMediaTestClient: OneDriveServing {
    let file: OneDriveItem
    init(file: OneDriveItem) { self.file = file }
    func account() -> OneDriveAccount { OneDriveAccount(driveID: "synthetic-drive", displayName: "Synthetic") }
    func children(of: String?, nextLink: URL?) -> OneDrivePage { OneDrivePage(items: [file], nextLink: nil) }
    func item(id: String) -> OneDriveItem {
        OneDriveItem(id: id, name: file.name, size: file.size, mimeType: file.mimeType, eTag: file.eTag, driveID: file.driveID)
    }
    func downloadURL(for id: String) -> URL { URL(string: "https://content.example.invalid/" + id + "?signature=synthetic-only")! }
}

private final class OneDriveMediaTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              let url = request.url, url.host == "content.example.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
        }
        let path = url.lastPathComponent
        guard path != "never-requested" else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let body = path == "partial" ? Data("short".utf8) : Data("hello world\n".utf8)
        var headers = ["Content-Type": "text/plain"]
        if path == "complete" { headers["Content-Length"] = "12" }
        if path == "wrong-length" { headers["Content-Length"] = "99" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.hasPrefix("hang") { return }
        // Separate chunks exercise incremental writes and unknown-size limits.
        for offset in stride(from: 0, to: body.count, by: 4) { client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + 4, body.count))) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
