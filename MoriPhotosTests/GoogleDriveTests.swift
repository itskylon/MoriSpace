#if targetEnvironment(simulator)
import Foundation
import XCTest
@testable import MoriPhotos

// Each session carries a private fixture identifier, so these tests cannot
// accidentally intercept requests from the NAS fixtures or another test.
private final class DriveHTTPFixture: @unchecked Sendable {
    enum Reply {
        case response(Int, Data, [String: String] = [:])
        case pending
    }
    private static let registryLock = NSLock()
    private static var registry: [String: DriveHTTPFixture] = [:]
    private let lock = NSLock()
    private let identifier = UUID().uuidString
    private var captured: [URLRequest] = []
    private var handler: (URLRequest) throws -> Reply

    init(_ handler: @escaping (URLRequest) throws -> Reply) {
        self.handler = handler
        Self.registryLock.lock(); Self.registry[identifier] = self; Self.registryLock.unlock()
    }
    func close() {
        Self.registryLock.lock(); Self.registry[identifier] = nil; Self.registryLock.unlock()
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func change(_ handler: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Mori-Drive-Fixture": identifier]
        return configuration
    }
    static func fixture(for request: URLRequest) -> DriveHTTPFixture? {
        guard let identifier = request.value(forHTTPHeaderField: "X-Mori-Drive-Fixture") else { return nil }
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[identifier]
    }
    func reply(_ request: URLRequest) throws -> Reply {
        lock.lock(); captured.append(request); let callback = handler; lock.unlock()
        return try callback(request)
    }
}

private final class DriveFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.googleapis.com" && DriveHTTPFixture.fixture(for: request) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = DriveHTTPFixture.fixture(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        do {
            switch try fixture.reply(request) {
            case .pending: return
            case .response(let status, let data, var headers):
                headers["Content-Length"] = String(data.count)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class GoogleDriveTests: XCTestCase {
    private let owner = "drive-test-owner"
    private let accessToken = "fixture-access-token-never-in-a-url"
    private let binary = Data([0x50, 0x4b, 0xff, 0x00, 0x0a, 0xe4, 0xb8, 0xad])

    private func client(_ fixture: DriveHTTPFixture, owner: String = "drive-test-owner") -> GoogleDriveClient {
        let token = accessToken
        return GoogleDriveClient(accountID: owner, tokenProvider: { token }, configuration: fixture.configuration(),
                                 transferConfiguration: { fixture.configuration() })
    }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func file(id: String = "file_123", name: String = "测试 + file.bin", size: Int64? = nil) -> GoogleDriveFile {
        GoogleDriveFile(id: id, name: name, mimeType: "application/octet-stream", size: size)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDriveTest-" + UUID().uuidString) }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for Google Drive download state", file: file, line: line)
    }

    func testFolderListingUsesReadOnlyFieldsAndBearerHeaderWithoutLeakingToken() async throws {
        let fixture = DriveHTTPFixture { _ in .response(200, Data(#"{"files":[]}"#.utf8)) }
        defer { fixture.close() }
        let page = try await client(fixture).list(folderID: "folder_123-ABC")
        XCTAssertTrue(page.files.isEmpty)
        let request = try XCTUnwrap(fixture.requests.first)
        let parameters = query(request)
        XCTAssertEqual(request.url?.path, "/drive/v3/files")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + accessToken)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.url!.absoluteString.contains(accessToken))
        XCTAssertEqual(parameters["q"], "trashed = false and ('folder_123-ABC' in parents)")
        XCTAssertEqual(parameters["spaces"], "drive")
        XCTAssertEqual(parameters["fields"], "nextPageToken,files(id,name,mimeType,size,modifiedTime,capabilities(canDownload))")
        XCTAssertEqual(parameters["pageSize"], "100")
        XCTAssertEqual(parameters["supportsAllDrives"], "true")
        XCTAssertEqual(parameters["includeItemsFromAllDrives"], "true")
    }

    func testSearchEscapesApostrophesAndBackslashesAndSearchesWholeDrive() async throws {
        let fixture = DriveHTTPFixture { _ in .response(200, Data(#"{"files":[]}"#.utf8)) }
        defer { fixture.close() }
        _ = try await client(fixture).list(folderID: "nested_folder", search: "  Bob's \\ share  ")
        let filter = query(try XCTUnwrap(fixture.requests.first))["q"]
        XCTAssertEqual(filter, #"trashed = false and (name contains 'Bob\'s \\ share')"#)
        XCTAssertFalse(filter?.contains("in parents") == true, "A search must not silently remain limited to the current folder")
    }

    func testPaginationPassesOpaquePageTokenWithoutChangingTheFilter() async throws {
        let fixture = DriveHTTPFixture { _ in .response(200, Data(#"{"files":[],"nextPageToken":"next+/=opaque"}"#.utf8)) }
        defer { fixture.close() }
        let drive = client(fixture)
        let first = try await drive.list(folderID: "folder_123")
        _ = try await drive.list(folderID: "folder_123", pageToken: first.nextPageToken)
        XCTAssertEqual(first.nextPageToken, "next+/=opaque")
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertNil(query(fixture.requests[0])["pageToken"])
        XCTAssertEqual(query(fixture.requests[1])["pageToken"], "next+/=opaque")
        XCTAssertEqual(query(fixture.requests[0])["q"], query(fixture.requests[1])["q"])
    }

    func testDriveDecodesStringSizesAndFractionalAndWholeSecondDates() async throws {
        let body = #"{"files":[{"id":"one","name":"one.bin","mimeType":"application/octet-stream","size":"9007199254740993","modifiedTime":"2026-10-19T05:06:07.123Z","capabilities":{"canDownload":true}},{"id":"two","name":"two.bin","mimeType":"application/octet-stream","size":8,"modifiedTime":"2026-10-19T05:06:07Z"},{"id":"folder","name":"folder","mimeType":"application/vnd.google-apps.folder"}]}"#
        let fixture = DriveHTTPFixture { _ in .response(200, Data(body.utf8)) }
        defer { fixture.close() }
        let page = try await client(fixture).list()
        XCTAssertEqual(page.files[0].size, 9_007_199_254_740_993, "Drive string sizes must not lose precision through Double")
        XCTAssertEqual(page.files[1].size, 8)
        let fraction = try XCTUnwrap(page.files[0].modifiedTime)
        let whole = try XCTUnwrap(page.files[1].modifiedTime)
        XCTAssertEqual(fraction.timeIntervalSince(whole), 0.123, accuracy: 0.001)
        XCTAssertNil(page.files[2].size)
        XCTAssertTrue(page.files[2].isFolder)
    }

    func testInvalidIdentifiersAreRejectedBeforeNetworkAccess() async throws {
        let fixture = DriveHTTPFixture { _ in XCTFail("Invalid IDs must never reach the network"); return .pending }
        defer { fixture.close() }
        let drive = client(fixture)
        for invalid in ["", "../secret", "file?alt=media", "file#fragment", "file%2Fsecret", String(repeating: "a", count: 1025)] {
            do { _ = try await drive.fileInfo(id: invalid); XCTFail("Accepted invalid ID") }
            catch { XCTAssertEqual(error as? GoogleDriveError, .invalidID) }
            do { _ = try await drive.list(folderID: invalid); XCTFail("Accepted invalid folder ID") }
            catch { XCTAssertEqual(error as? GoogleDriveError, .invalidID) }
            do { _ = try await drive.download(file(id: invalid), progress: { _, _ in }); XCTFail("Accepted invalid download ID") }
            catch { XCTAssertEqual(error as? GoogleDriveError, .invalidID) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testEmptyAccessTokenRequiresSignInBeforeSendingRequest() async throws {
        let fixture = DriveHTTPFixture { _ in XCTFail("Empty token must not be sent"); return .pending }
        defer { fixture.close() }
        let drive = GoogleDriveClient(accountID: owner, tokenProvider: { "" }, configuration: fixture.configuration())
        do { _ = try await drive.list(); XCTFail("Expected sign-in failure") }
        catch { XCTAssertEqual(error as? GoogleDriveError, .signInRequired) }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testAPIErrorReasonsMapToSafeActionableErrors() async throws {
        let secret = "server-body-with-sensitive-material"
        let cases: [(Int, String?, GoogleDriveError)] = [
            (401, nil, .signInRequired), (403, nil, .forbidden), (404, nil, .notFound),
            (429, nil, .rateLimited), (302, nil, .redirect), (503, nil, .http(503)),
            (403, "accessNotConfigured", .apiDisabled), (403, "serviceDisabled", .apiDisabled),
            (403, "exportSizeLimitExceeded", .exportTooLarge), (403, "downloadQuotaExceeded", .rateLimited),
            (403, "userRateLimitExceeded", .rateLimited)
        ]
        for (status, reason, expected) in cases {
            let body = try json(["error": ["message": secret, "errors": reason.map { [["reason": $0]] } ?? []]])
            let fixture = DriveHTTPFixture { _ in .response(status, body) }
            defer { fixture.close() }
            do { _ = try await client(fixture).list(); XCTFail("Expected HTTP \(status) error") }
            catch {
                XCTAssertEqual(error as? GoogleDriveError, expected)
                XCTAssertFalse(googleDriveErrorMessage(error).contains(secret))
                XCTAssertFalse(googleDriveErrorMessage(error).contains(accessToken))
            }
        }
    }

    func testUserMessagesNeverDisplayArbitraryErrorsAndDistinguishNetworkFailures() {
        let unsafe = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-token=do-not-display"])
        XCTAssertFalse(googleDriveErrorMessage(unsafe).contains("private-token"))
        XCTAssertTrue(googleDriveErrorMessage(URLError(.notConnectedToInternet)).contains("网络连接已断开"))
        XCTAssertTrue(googleDriveErrorMessage(URLError(.timedOut)).contains("超时"))
        XCTAssertTrue(googleDriveErrorMessage(URLError(.serverCertificateUntrusted)).contains("安全连接"))
        XCTAssertEqual(googleDriveErrorMessage(CancellationError()), "操作已取消。")
    }

    func testGoogleNativeExportsAndDownloadRestrictions() {
        for (kind, ext) in [("document", "docx"), ("spreadsheet", "xlsx"), ("presentation", "pptx"), ("drawing", "pdf")] {
            let native = GoogleDriveFile(id: "native", name: "work", mimeType: "application/vnd.google-apps." + kind)
            XCTAssertEqual(native.exportFormat?.fileExtension, ext)
            XCTAssertTrue(native.canDownload)
        }
        for kind in ["folder", "shortcut", "form", "unknown"] {
            XCTAssertFalse(GoogleDriveFile(id: "native", name: "work", mimeType: "application/vnd.google-apps." + kind).canDownload)
        }
        let restricted = GoogleDriveFile(id: "locked", name: "work.pdf", mimeType: "application/pdf", capabilities: .init(canDownload: false))
        XCTAssertFalse(restricted.canDownload)
    }

    func testDownloadNamesStayInsideRecordFolderAndPreserveExportExtension() {
        for name in ["../../secret:report.txt", "..", ".", "", "nul\u{0}name", String(repeating: "照片", count: 200) + ".jpg"] {
            let record = GoogleDriveDownload(id: UUID(), owner: owner, file: file(name: name), created: Date())
            XCTAssertFalse(record.localName.contains("/"))
            XCTAssertFalse(record.localName.contains(":"))
            XCTAssertFalse(record.localName.contains("\u{0}"))
            XCTAssertFalse(["", ".", ".."].contains(record.localName))
            XCTAssertLessThanOrEqual(record.localName.utf8.count, 220)
        }
        let native = GoogleDriveFile(id: "doc", name: String(repeating: "文", count: 200), mimeType: "application/vnd.google-apps.document")
        let record = GoogleDriveDownload(id: UUID(), owner: owner, file: native, created: Date())
        XCTAssertTrue(record.localName.hasSuffix(".docx"))
        XCTAssertLessThanOrEqual(record.localName.utf8.count, 220)
    }

    func testBinaryDownloadUsesMediaEndpointAndVerifiesActualBytes() async throws {
        let bytes = binary
        let fixture = DriveHTTPFixture { _ in .response(200, bytes, ["Content-Type": "application/octet-stream"]) }
        defer { fixture.close() }
        let location = try await client(fixture).download(file(size: Int64(bytes.count)), progress: { _, _ in })
        defer { try? FileManager.default.removeItem(at: location) }
        XCTAssertEqual(try Data(contentsOf: location), bytes)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.url?.path, "/drive/v3/files/file_123")
        XCTAssertEqual(query(request)["alt"], "media")
        XCTAssertEqual(query(request)["supportsAllDrives"], "true")
        XCTAssertFalse(request.url!.absoluteString.contains(accessToken))
    }

    func testGoogleDocumentDownloadUsesExportMIMEInsteadOfMedia() async throws {
        let fixture = DriveHTTPFixture { _ in .response(200, Data("exported-office-document".utf8)) }
        defer { fixture.close() }
        let native = GoogleDriveFile(id: "doc_123", name: "notes", mimeType: "application/vnd.google-apps.document", size: 99999)
        let location = try await client(fixture).download(native, progress: { _, _ in })
        defer { try? FileManager.default.removeItem(at: location) }
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.url?.path, "/drive/v3/files/doc_123/export")
        XCTAssertEqual(query(request)["mimeType"], "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertNil(query(request)["alt"])
        XCTAssertEqual(try Data(contentsOf: location), Data("exported-office-document".utf8), "Export bytes are not expected to match the source document's Drive size")
    }

    func testTruncatedDownloadAndUnsupportedNativeFileFail() async throws {
        let fixture = DriveHTTPFixture { _ in .response(200, Data([1, 2, 3])) }
        defer { fixture.close() }
        let drive = client(fixture)
        do { _ = try await drive.download(file(size: 4), progress: { _, _ in }); XCTFail("Accepted a truncated file") }
        catch { XCTAssertEqual(error as? GoogleDriveError, .incomplete) }
        let before = fixture.requests.count
        do {
            _ = try await drive.download(GoogleDriveFile(id: "form", name: "survey", mimeType: "application/vnd.google-apps.form"), progress: { _, _ in })
            XCTFail("Unsupported native files must fail before transfer")
        } catch { XCTAssertEqual(error as? GoogleDriveError, .notDownloadable) }
        XCTAssertEqual(fixture.requests.count, before)
    }

    func testQueuePersistsRealBytesForOfflineUseAndRejectsWrongOwner() async throws {
        let root = directory(), bytes = binary
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try json(["id": "file_123", "name": "下载 + test.bin", "mimeType": "application/octet-stream", "size": String(bytes.count)])
        let fixture = DriveHTTPFixture { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "alt" }) == true
                ? .response(200, bytes, ["Content-Type": "application/octet-stream"]) : .response(200, metadata)
        }
        defer { fixture.close() }
        let drive = client(fixture), queue = GoogleDriveDownloads(directory: root)
        queue.enqueue(file(size: Int64(bytes.count)), owner: "other-owner", client: drive)
        XCTAssertTrue(queue.records.isEmpty)
        queue.enqueue(file(size: Int64(bytes.count)), owner: owner, client: drive)
        queue.enqueue(file(size: Int64(bytes.count)), owner: owner, client: drive)
        XCTAssertEqual(queue.records.count, 1, "An active download must not be enqueued twice")
        await wait { queue.records.first?.active == false }
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(record.state, .completed, record.message ?? "")
        XCTAssertEqual(record.received, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: queue.fileURL(record)), bytes)
        XCTAssertEqual(queue.fileURL(record).lastPathComponent, "下载 + test.bin")
        let offline = GoogleDriveDownloads(directory: root)
        XCTAssertEqual(offline.records.first?.state, .completed)
        XCTAssertEqual(offline.records.first?.owner, owner)
        XCTAssertEqual(try Data(contentsOf: offline.fileURL(record)), bytes)
        let manifest = try String(contentsOf: root.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(accessToken))
        offline.remove(try XCTUnwrap(offline.records.first))
        XCTAssertTrue(offline.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: offline.fileURL(record).path))
    }

    func testQueueFailureCanRetryButOnlyForItsOriginalOwner() async throws {
        let root = directory(), bytes = binary
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try json(["id": "file_123", "name": "retry.bin", "mimeType": "application/octet-stream", "size": String(bytes.count)])
        let fixture = DriveHTTPFixture { _ in .response(403, Data(#"{"error":{"message":"do-not-display-this-server-detail"}}"#.utf8)) }
        defer { fixture.close() }
        let drive = client(fixture), queue = GoogleDriveDownloads(directory: root)
        queue.enqueue(file(), owner: owner, client: drive)
        await wait { queue.records.first?.state == .failed }
        let failed = try XCTUnwrap(queue.records.first)
        XCTAssertFalse(failed.message?.contains("do-not-display") == true)
        let count = fixture.requests.count
        queue.retry(failed, client: drive, owner: "other-owner")
        queue.retry(failed, client: client(fixture, owner: "other-owner"), owner: owner)
        XCTAssertEqual(queue.records.first?.state, .failed)
        XCTAssertEqual(fixture.requests.count, count)
        fixture.change { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "alt" }) == true
                ? .response(200, bytes) : .response(200, metadata)
        }
        queue.retry(failed, client: drive, owner: owner)
        await wait { queue.records.first?.state == .completed }
        XCTAssertEqual(try Data(contentsOf: queue.fileURL(try XCTUnwrap(queue.records.first))), bytes)
    }

    func testTwoConcurrentDownloadsForOneOwnerAcceptDifferentClientInstances() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payloads = ["first_file": Data("first download bytes".utf8), "second_file": Data("second download bytes".utf8)]
        let fixture = DriveHTTPFixture { request in
            let id = request.url!.lastPathComponent
            guard let bytes = payloads[id] else { throw URLError(.fileDoesNotExist) }
            if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "alt" }) == true {
                return .response(200, bytes, ["Content-Type": "application/octet-stream"])
            }
            let metadata = try JSONSerialization.data(withJSONObject: ["id": id, "name": id + ".bin", "mimeType": "application/octet-stream", "size": String(bytes.count)])
            return .response(200, metadata)
        }
        defer { fixture.close() }
        let firstClient = client(fixture), secondClient = client(fixture)
        XCTAssertFalse(firstClient === secondClient)
        let queue = GoogleDriveDownloads(directory: root)
        // Both enqueues run before yielding the main actor. The second UI action
        // replaces the account's cached client while the first job retains its
        // own client, which must remain valid for that same signed-in account.
        queue.enqueue(file(id: "first_file"), owner: owner, client: firstClient)
        queue.enqueue(file(id: "second_file"), owner: owner, client: secondClient)
        XCTAssertEqual(queue.records.count, 2)
        XCTAssertTrue(queue.records.allSatisfy { $0.state == .downloading })
        await wait { queue.records.allSatisfy { !$0.active } }
        XCTAssertTrue(queue.records.allSatisfy { $0.state == .completed }, queue.records.compactMap(\.message).joined(separator: "; "))
        for record in queue.records {
            XCTAssertEqual(try Data(contentsOf: queue.fileURL(record)), payloads[record.file.id])
            XCTAssertEqual(record.owner, owner)
        }
        XCTAssertEqual(fixture.requests.count, 4, "Both files must fetch fresh metadata and complete their own media transfer")
        let offline = GoogleDriveDownloads(directory: root)
        XCTAssertEqual(offline.records.count, 2)
        XCTAssertTrue(offline.records.allSatisfy { $0.state == .completed })
    }

    func testRetryChecksPersistedOwnerInsteadOfTrustingACraftedSnapshot() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = GoogleDriveDownload(id: UUID(), owner: owner, file: file(), created: Date())
        original.state = .failed
        try JSONEncoder().encode([original]).write(to: root.appendingPathComponent("downloads.json"))
        let fixture = DriveHTTPFixture { _ in XCTFail("Another account must not start this retry"); return .pending }
        defer { fixture.close() }
        let queue = GoogleDriveDownloads(directory: root)
        var forged = GoogleDriveDownload(id: original.id, owner: "other-owner", file: original.file, created: original.created)
        forged.state = .failed
        queue.retry(forged, client: client(fixture, owner: "other-owner"), owner: "other-owner")
        XCTAssertEqual(queue.records.first?.owner, owner)
        XCTAssertEqual(queue.records.first?.state, .failed)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testDisconnectCancelsOnlyThatOwnersJobsAndDoesNotPublishFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DriveHTTPFixture { _ in .pending }
        defer { fixture.close() }
        let queue = GoogleDriveDownloads(directory: root)
        queue.enqueue(file(id: "first"), owner: owner, client: client(fixture))
        queue.enqueue(file(id: "second"), owner: "other-owner", client: client(fixture, owner: "other-owner"))
        await wait { fixture.requests.count == 2 }
        queue.cancelActive(owner: owner)
        let first = try XCTUnwrap(queue.records.first(where: { $0.owner == owner }))
        XCTAssertEqual(first.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL(first).path))
        XCTAssertTrue(queue.records.first(where: { $0.owner == "other-owner" })?.active == true)
        queue.cancelActive(owner: "other-owner")
        await wait { queue.records.allSatisfy { !$0.active } }
        // Allow the cancelled async continuations to drain before deleting storage.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(queue.records.allSatisfy { $0.state == .cancelled })
    }

    func testRelaunchMarksInterruptedAndMissingCompletedDownloadsForRetry() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var interrupted = GoogleDriveDownload(id: UUID(), owner: owner, file: file(id: "pending"), created: Date())
        interrupted.state = .downloading
        var missing = GoogleDriveDownload(id: UUID(), owner: owner, file: file(id: "missing"), created: Date())
        missing.state = .completed
        try JSONEncoder().encode([interrupted, missing]).write(to: root.appendingPathComponent("downloads.json"))
        let restored = GoogleDriveDownloads(directory: root)
        XCTAssertEqual(restored.records.map(\.state), [.failed, .failed])
        XCTAssertTrue(restored.records[0].message?.contains("中断") == true)
        XCTAssertTrue(restored.records[1].message?.contains("不存在") == true)
        XCTAssertTrue(restored.records.allSatisfy { $0.owner == owner })
    }

    func testRetryReplacesOnlyItsOwnFileLeftByInterruptedCompletion() async throws {
        let root = directory(), bytes = binary
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var interrupted = GoogleDriveDownload(id: UUID(), owner: owner, file: file(name: "retry.bin"), created: Date())
        interrupted.state = .downloading
        try JSONEncoder().encode([interrupted]).write(to: root.appendingPathComponent("downloads.json"))
        let target = root.appendingPathComponent(interrupted.id.uuidString).appendingPathComponent(interrupted.localName)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bytes moved before manifest recorded completion".utf8).write(to: target)
        let unrelated = root.appendingPathComponent("unrelated-local-file.bin")
        let unrelatedBytes = Data("keep this local file unchanged".utf8)
        try unrelatedBytes.write(to: unrelated)
        let metadata = try json(["id": "file_123", "name": "retry.bin", "mimeType": "application/octet-stream", "size": String(bytes.count)])
        let fixture = DriveHTTPFixture { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "alt" }) == true
                ? .response(200, bytes) : .response(200, metadata)
        }
        defer { fixture.close() }
        let restored = GoogleDriveDownloads(directory: root)
        XCTAssertEqual(restored.records.first?.state, .failed)
        restored.retry(try XCTUnwrap(restored.records.first), client: client(fixture), owner: owner)
        await wait { restored.records.first?.active == false }
        XCTAssertEqual(restored.records.first?.state, .completed, restored.records.first?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
    }

    func testUnreadableManifestIsPreservedInsteadOfReplacingExistingDownloads() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("downloads.json")
        let original = Data("existing manifest cannot currently be decoded".utf8)
        try original.write(to: manifest)
        let queue = GoogleDriveDownloads(directory: root)
        XCTAssertNotNil(queue.error)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        queue.reloadIfNeeded()
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        try Data("[]".utf8).write(to: manifest)
        queue.reloadIfNeeded()
        XCTAssertNil(queue.error)
        XCTAssertTrue(queue.records.isEmpty)
    }
}
#endif
