import XCTest
import Photos
import UIKit
import CryptoKit
@testable import MoriPhotos

final class PhotoBackupTests: XCTestCase {
    private let credentials = NASCredentials(address: "https://backup.example.invalid", username: "backup-fixture", password: "fixture-only")
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testOnlyNewPhotosExcludeScreenshotsCompletedAndDuplicates() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var ledger = BackupLedger()
        try ledger.enable(owner: "owner", folder: "/home/Photos/MoriBackup", wifiOnly: true, now: start)
        ledger.completed = ["done"]
        let candidates = [BackupCandidate(id: "old", created: start.addingTimeInterval(-1), isScreenshot: false),
                          BackupCandidate(id: "new", created: start.addingTimeInterval(1), isScreenshot: false),
                          BackupCandidate(id: "new", created: start.addingTimeInterval(1), isScreenshot: false),
                          BackupCandidate(id: "screenshot", created: start, isScreenshot: true),
                          BackupCandidate(id: "done", created: start, isScreenshot: false),
                          BackupCandidate(id: "boundary", created: start, isScreenshot: false)]
        XCTAssertEqual(ledger.pending(candidates).map(\.id), ["boundary", "new"])
        ledger.configuration.enabled = false
        XCTAssertTrue(ledger.pending(candidates).isEmpty)
    }
    func testReenableKeepsCutoffButDifferentDestinationOrAccountStartsFresh() throws {
        var ledger = BackupLedger()
        try ledger.enable(owner: "one", folder: "/home/Photos/Backup", wifiOnly: true, now: Date(timeIntervalSince1970: 100))
        ledger.completed = ["saved"]
        ledger.configuration.enabled = false
        try ledger.enable(owner: "one", folder: "/home/Photos/Backup", wifiOnly: false, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ledger.configuration.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(ledger.completed, ["saved"])
        try ledger.enable(owner: "two", folder: "/home/Photos/Backup", wifiOnly: true, now: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(ledger.completed.isEmpty)
        XCTAssertEqual(ledger.configuration.startedAt, Date(timeIntervalSince1970: 300))
        XCTAssertThrowsError(try ledger.enable(owner: "two", folder: "/home/../Photos", wifiOnly: true, now: Date()))
    }
    func testLedgerRoundTripAndCorruptionIsNotTreatedAsAnEmptyHistory() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = BackupLedgerFile(url: directory.appendingPathComponent("ledger.json"))
        var ledger = BackupLedger()
        try ledger.enable(owner: "owner", folder: "/home/Photos/Backup", wifiOnly: true, now: Date())
        ledger.completed = ["a", "b"]
        try file.save(ledger)
        XCTAssertEqual(try file.load().completed, ledger.completed)
        let damaged = Data("damaged history".utf8); try damaged.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), damaged)
    }
    func testFolderChoicePersistsWhileOffAndActiveChangeResetsReceiptsAtomically() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = BackupLedgerFile(url: directory.appendingPathComponent("ledger.json"))
        var ledger = BackupLedger()
        try ledger.selectFolder(owner: "owner", folder: "/photo/我的照片", now: Date(timeIntervalSince1970: 100))
        try file.save(ledger)
        ledger = try file.load()
        XCTAssertFalse(ledger.configuration.enabled)
        XCTAssertNil(ledger.configuration.startedAt)
        XCTAssertEqual(ledger.configuration.folder, "/photo/我的照片")
        try ledger.enable(owner: "owner", folder: ledger.configuration.folder, wifiOnly: true, now: Date(timeIntervalSince1970: 200))
        ledger.completed.insert("old-target-photo")
        try ledger.selectFolder(owner: "owner", folder: ledger.configuration.folder, now: Date(timeIntervalSince1970: 250))
        XCTAssertEqual(ledger.completed, ["old-target-photo"])
        try ledger.selectFolder(owner: "owner", folder: "/photo/新目录", now: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(ledger.configuration.enabled)
        XCTAssertTrue(ledger.completed.isEmpty)
        XCTAssertEqual(ledger.configuration.startedAt, Date(timeIntervalSince1970: 300))
    }
    func testMultipartPreservesOriginalBytesAndPlacesFileLast() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0, 1, 255, 128, 10, 13]) + Data("原图 bytes + &".utf8)
        let url = directory.appendingPathComponent("source"); try bytes.write(to: url)
        let original = try BackupOriginal.inspect(url: url, assetID: "asset-one", resourceType: 1, originalName: "中文照片.HEIC", created: Date())
        let same = try BackupOriginal.inspect(url: url, assetID: "asset-one", resourceType: 1, originalName: "中文照片.HEIC", created: Date())
        let different = try BackupOriginal.inspect(url: url, assetID: "asset-two", resourceType: 1, originalName: "中文照片.HEIC", created: Date())
        XCTAssertEqual(original.filename, same.filename); XCTAssertNotEqual(original.filename, different.filename)
        let output = directory.appendingPathComponent("body")
        let count = try BackupMultipart.write(fields: [("path", "/共享/照片 + 原图"), ("overwrite", "false")], original: original, to: output, boundary: "TestBoundary")
        let multipart = try Data(contentsOf: output)
        let parsed = try BackupTestServer.parseMultipart(multipart, boundary: "TestBoundary")
        XCTAssertEqual(count, Int64(multipart.count))
        XCTAssertEqual(parsed.fields["path"], "/共享/照片 + 原图")
        XCTAssertEqual(parsed.fields["overwrite"], "false")
        XCTAssertEqual(parsed.bytes, bytes)
        XCTAssertEqual(parsed.filename, original.filename)
        XCTAssertTrue(multipart.suffix(Data("\r\n--TestBoundary--\r\n".utf8).count) == Data("\r\n--TestBoundary--\r\n".utf8))
    }
    func testVerifiedUploadIsIdempotentAndDoesNotOverwriteConflictingFile() async throws {
        let server = BackupTestServer(); BackupTestURLProtocol.server = server
        let client = try makeClient(); try await client.login(credentials, otp: "")
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo"); let bytes = Data("original photo bytes".utf8); try bytes.write(to: source)
        let original = try BackupOriginal.inspect(url: source, assetID: "new-photo", resourceType: 1, originalName: "image.heic", created: Date())
        let folder = "/home/Photos/MoriBackup/2026/09"
        try await client.verifyBackupDestination("/home/Photos/MoriBackup")
        try await client.uploadBackupOriginal(original, folder: folder, wifiOnly: true)
        XCTAssertEqual(server.files[folder + "/" + original.filename], bytes)
        try await client.uploadBackupOriginal(original, folder: folder, wifiOnly: true)
        XCTAssertEqual(server.uploadCount, 1)
        server.files[folder + "/" + original.filename] = Data(repeating: 99, count: bytes.count)
        do { try await client.uploadBackupOriginal(original, folder: folder, wifiOnly: true); XCTFail("A mismatching existing file must not be overwritten") }
        catch { XCTAssertTrue(error is PhotoBackupError) }
        XCTAssertEqual(server.uploadCount, 1)
        await client.close()
    }
    func testLostUploadResponseRetryVerifiesServerCopyWithoutUploadingTwice() async throws {
        let server = BackupTestServer(); server.loseNextAcknowledgement = true; BackupTestURLProtocol.server = server
        let client = try makeClient(); try await client.login(credentials, otp: "")
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo"); try Data("acknowledgement test".utf8).write(to: source)
        let original = try BackupOriginal.inspect(url: source, assetID: "photo", resourceType: 1, originalName: "image.jpg", created: Date())
        do { try await client.uploadBackupOriginal(original, folder: "/home/Photos/Backup", wifiOnly: true); XCTFail("Simulate dropped connection after NAS committed bytes") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await client.uploadBackupOriginal(original, folder: "/home/Photos/Backup", wifiOnly: true)
        XCTAssertEqual(server.uploadCount, 1)
        await client.close()
    }
    @MainActor
    func testPhotoLibraryChangeAutomaticallyBacksUpOnlyNewOriginalAndPersistsReceipt() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw XCTSkip("Requires photo access in isolated simulator") }
        let server = BackupTestServer(); BackupTestURLProtocol.server = server
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let saved = SavedNASConnection(credentials: credentials)
        let app = AppState(persistence: ConnectionPersistence(load: { saved }, save: { _ in }, delete: {}), makeClient: { _, service in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackupTestURLProtocol.self]
            return try SynologyClient(address: saved.credentials.address, service: service, session: URLSession(configuration: config))
        })
        let ledgerFile = BackupLedgerFile(url: directory.appendingPathComponent("receipts.json"))
        let backup = PhotoBackupManager(app: app, file: ledgerFile)
        backup.foregroundChanged(true)
        await backup.enable(folder: "/home/Photos/MoriBackup", wifiOnly: false)
        XCTAssertNil(backup.error); XCTAssertTrue(backup.configuration.enabled)
        try await wait { !backup.running && backup.status == "等待新照片" }
        XCTAssertEqual(server.uploadCount, 0, "Existing simulator photos are excluded")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let bytes = try XCTUnwrap(renderer.image { c in UIColor.systemMint.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 48)) }.pngData())
        let source = directory.appendingPathComponent("new-camera-fixture.png"); try bytes.write(to: source)
        try await PHPhotoLibrary.shared().performChanges {
            let asset = PHAssetCreationRequest.forAsset(); asset.creationDate = Date()
            asset.addResource(with: .photo, fileURL: source, options: nil)
        }
        // No explicit checkNow: PhotoKit's change observer must trigger the upload.
        try await wait { backup.ledger.completed.count == 1 }
        XCTAssertNil(backup.error)
        XCTAssertEqual(server.uploadCount, 1)
        XCTAssertEqual(server.files.values.first, bytes)
        backup.checkNow()
        try await wait { !backup.running }
        XCTAssertEqual(server.uploadCount, 1)
        XCTAssertEqual(try ledgerFile.load().completed.count, 1)
        backup.foregroundChanged(false)
        let restored = PhotoBackupManager(app: app, file: ledgerFile)
        restored.foregroundChanged(true)
        try await wait { restored.status == "新照片已全部备份" }
        XCTAssertEqual(server.uploadCount, 1, "Relaunch uses durable receipts")
        restored.disable(); backup.disable()
        await app.disconnect()
    }
    @MainActor
    func testActiveFolderChangeKeepsBackupEnabledAndFailedChoiceKeepsOldTarget() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw XCTSkip("Requires photo access in isolated simulator") }
        let server = BackupTestServer(); BackupTestURLProtocol.server = server
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let saved = SavedNASConnection(credentials: credentials)
        let app = AppState(persistence: ConnectionPersistence(load: { saved }, save: { _ in }, delete: {}), makeClient: { _, service in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackupTestURLProtocol.self]
            return try SynologyClient(address: saved.credentials.address, service: service, session: URLSession(configuration: config))
        })
        let file = BackupLedgerFile(url: directory.appendingPathComponent("ledger.json"))
        let backup = PhotoBackupManager(app: app, file: file)
        backup.foregroundChanged(true)
        await backup.enable(folder: "/home/Photos/Original", wifiOnly: false)
        XCTAssertTrue(backup.configuration.enabled)
        let chosen = await backup.selectFolder("/home/Photos/Selected", owner: app.fileAccountID)
        XCTAssertTrue(chosen)
        XCTAssertTrue(backup.configuration.enabled)
        XCTAssertEqual(try file.load().configuration.folder, "/home/Photos/Selected")
        server.denyWrites = true
        let rejected = await backup.selectFolder("/home/Photos/ReadOnly", owner: app.fileAccountID)
        XCTAssertFalse(rejected)
        XCTAssertNotNil(backup.folderError)
        XCTAssertEqual(backup.configuration.folder, "/home/Photos/Selected")
        XCTAssertTrue(backup.configuration.enabled)
        backup.disable(); await app.disconnect()
    }

    private func makeClient() throws -> SynologyClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackupTestURLProtocol.self]
        return try SynologyClient(address: credentials.address, service: .files, session: URLSession(configuration: config))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("Backup condition timed out")
    }
}

private final class BackupTestURLProtocol: URLProtocol {
    static var server: BackupTestServer!
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "backup.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.server.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class BackupTestServer {
    var files: [String: Data] = [:]
    var uploadCount = 0
    var loseNextAcknowledgement = false
    var denyWrites = false
    private let lock = NSLock()
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(contentsOf: buffer.prefix(n)) }
        return result
    }
    struct Multipart { var fields: [String: String]; var filename: String; var bytes: Data }
    static func parseMultipart(_ bytes: Data, boundary: String) throws -> Multipart {
        let separator = Data("\r\n\r\n".utf8), marker = Data(("\r\n--" + boundary).utf8)
        var cursor = Data(("--" + boundary + "\r\n").utf8).count
        var result = Multipart(fields: [:], filename: "", bytes: Data())
        while cursor < bytes.count {
            guard let headersEnd = bytes.range(of: separator, in: cursor..<bytes.count),
                  let end = bytes.range(of: marker, in: headersEnd.upperBound..<bytes.count) else { break }
            let header = String(decoding: bytes[cursor..<headersEnd.lowerBound], as: UTF8.self)
            let value = Data(bytes[headersEnd.upperBound..<end.lowerBound])
            if header.contains("filename=") {
                result.filename = header.components(separatedBy: "filename=\"")[1].components(separatedBy: "\"")[0]
                result.bytes = value
                XCTAssertEqual(end.upperBound + 4, bytes.count, "Binary file is the final part")
            } else {
                let name = header.components(separatedBy: "name=\"")[1].components(separatedBy: "\"")[0]
                result.fields[name] = String(decoding: value, as: UTF8.self)
            }
            cursor = end.upperBound + 2
        }
        return result
    }
    func reply(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let bytes = Self.body(request)
        XCTAssertNil(request.url?.query, "Sessions must stay out of URLs")
        if let type = request.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("multipart/") {
            let boundary = type.components(separatedBy: "boundary=")[1]
            let parsed = try Self.parseMultipart(bytes, boundary: boundary)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(bytes.count))
            XCTAssertEqual(parsed.fields["api"], "SYNO.FileStation.Upload")
            XCTAssertEqual(parsed.fields["overwrite"], "false")
            XCTAssertEqual(parsed.fields["create_parents"], "true")
            XCTAssertEqual(parsed.fields["_sid"], "backup-test-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=backup-test-session")
            let path = (parsed.fields["path"] ?? "") + "/" + parsed.filename
            if files[path] == nil { files[path] = parsed.bytes }
            uploadCount += 1
            if loseNextAcknowledgement { loseNextAcknowledgement = false; throw URLError(.timedOut) }
            return try json(["success": true])
        }
        var c = URLComponents(); c.percentEncodedQuery = String(data: bytes, encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        if api == "SYNO.API.Info" {
            var info: [String: Any] = [:]
            for key in ["SYNO.API.Auth", "SYNO.FileStation.List", "SYNO.FileStation.Upload", "SYNO.FileStation.MD5", "SYNO.FileStation.CheckPermission"] {
                info[key] = ["path": "entry.cgi", "minVersion": 1, "maxVersion": key == "SYNO.API.Auth" ? 7 : 3, "requestFormat": "JSON"]
            }
            return try json(["success": true, "data": info])
        }
        if method == "login" { return try json(["success": true, "data": ["sid": "backup-test-session", "synotoken": "backup-test-token"]]) }
        if method == "logout" { return try json(["success": true]) }
        if method == "getinfo" {
            let paths = try JSONDecoder().decode([String].self, from: Data((fields["path"] ?? "[]").utf8)); let path = paths[0]
            guard let data = files[path] else { return try missing() }
            return try json(["success": true, "data": ["files": [["name": (path as NSString).lastPathComponent, "path": path, "isdir": false, "additional": ["size": data.count]]]]])
        }
        if method == "list" {
            let path = try JSONDecoder().decode(String.self, from: Data((fields["folder_path"] ?? "\"\"").utf8))
            guard path == "/home/Photos" else { return try missing() }
            return try json(["success": true, "data": ["total": 0, "offset": 0, "files": []]])
        }
        if api == "SYNO.FileStation.CheckPermission" {
            if denyWrites { return try json(["success": false, "error": ["code": 407]]) }
            return try json(["success": true])
        }
        if api == "SYNO.FileStation.MD5" {
            if method == "start" {
                let path = try JSONDecoder().decode(String.self, from: Data((fields["file_path"] ?? "\"\"").utf8))
                return try json(["success": true, "data": ["taskid": path]])
            }
            if method == "status" {
                let path = try JSONDecoder().decode(String.self, from: Data((fields["taskid"] ?? "\"\"").utf8))
                let md5 = Insecure.MD5.hash(data: files[path] ?? Data()).map { String(format: "%02x", $0) }.joined()
                return try json(["success": true, "data": ["finished": true, "md5": md5]])
            }
            return try json(["success": true])
        }
        throw NASError.invalidResponse
    }
    private func missing() throws -> Data { try json(["success": false, "error": ["code": 1100, "errors": [["code": 408]]]]) }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}
