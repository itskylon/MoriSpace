import XCTest
import Photos
@testable import MoriPhotos

@MainActor
final class PhotoBackupManagerTests: XCTestCase {
    private final class Library {
        var authorization: PHAuthorizationStatus = .authorized
        var candidates: [BackupCandidate] = []
        var exportFailures: [String: Error] = [:]
        var uploadFailures: [String: Error] = [:]
        var uploaded: [String] = []
        var startedUploads: [String] = []
        var suspendUpload: (() async throws -> Void)?
        var beforeUpload: (() throws -> Void)?
    }
    @MainActor
    private struct Fixture {
        let directory: URL
        let file: BackupLedgerFile
        let initialLedger: BackupLedger
        let app: AppState
        let manager: PhotoBackupManager
        let library: Library
        func cleanUp() {
            manager.disable()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture(ids: [String] = ["first", "second"], wifiOnly: Bool = true, owner: String? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = BackupLedgerFile(url: directory.appendingPathComponent("ledger.json"))
        let credentials = NASCredentials(address: "https://backup-fixture.invalid", username: "fixture", password: "fixture")
        let saved = SavedNASConnection(credentials: credentials)
        let app = AppState(persistence: ConnectionPersistence(load: { saved }, save: { _ in }, delete: {}))
        // A client identity is sufficient: injected uploads never submit a request.
        app.fileClient = try SynologyClient(address: credentials.address, service: .files)
        let start = Date(timeIntervalSince1970: 1000)
        var ledger = BackupLedger()
        try ledger.enable(owner: owner ?? app.fileAccountID, folder: "/photo/Backup", wifiOnly: wifiOnly, now: start)
        try file.save(ledger)
        let library = Library()
        library.candidates = ids.enumerated().map { BackupCandidate(id: $0.element, created: start.addingTimeInterval(Double($0.offset + 1)), isScreenshot: false) }
        let operations = PhotoBackupOperations(authorization: { library.authorization }, candidates: { _ in library.candidates }, originals: { candidate, folder in
            if let failure = library.exportFailures[candidate.id] { throw failure }
            return [BackupOriginal(url: folder.appendingPathComponent(candidate.id), filename: candidate.id, bytes: 1, md5: "fixture", created: candidate.created)]
        }, upload: { _, original, _, _ in
            library.startedUploads.append(original.filename)
            if let failure = library.uploadFailures[original.filename] { throw failure }
            try library.beforeUpload?()
            try await library.suspendUpload?()
            library.uploaded.append(original.filename)
        })
        let manager = PhotoBackupManager(app: app, file: file, operations: operations, observesSystemChanges: false)
        return Fixture(directory: directory, file: file, initialLedger: ledger, app: app, manager: manager, library: library)
    }
    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Backup did not reach the expected state")
    }
    private func connectWiFi(_ manager: PhotoBackupManager) {
        manager.networkChanged(ready: true, wifi: true, expensive: false, constrained: false)
    }

    func testNetworkPolicyRequiresPositiveLocalInterfaceEvidenceAndRejectsCellular() {
        var path = PhotoBackupNetworkPolicy(ready: true)
        XCTAssertFalse(path.permitsUpload(wifiOnly: true), "An unknown VPN/other route is not evidence of Wi-Fi")
        path.wifiAvailable = true
        XCTAssertTrue(path.permitsUpload(wifiOnly: true), "An independently observed usable Wi-Fi route supplements a VPN path")
        path.wifiAvailable = false; path.ethernetAvailable = true
        XCTAssertTrue(path.permitsUpload(wifiOnly: true))
        path.usesCellular = true
        XCTAssertFalse(path.permitsUpload(wifiOnly: true), "Even an available Wi-Fi interface cannot authorize the current cellular path")
        path.usesCellular = false; path.expensive = true
        XCTAssertFalse(path.permitsUpload(wifiOnly: true))
        path.expensive = false; path.constrained = true
        XCTAssertEqual(path.waitingReason(wifiOnly: true), "等待关闭低数据模式")
        path.constrained = false; path.ready = false
        XCTAssertFalse(path.permitsUpload(wifiOnly: true))
        XCTAssertEqual(path.waitingReason(wifiOnly: true), "等待网络连接")
        path.restriction = .wifiDenied
        XCTAssertEqual(path.waitingReason(wifiOnly: true), "等待允许 App 使用 Wi-Fi")
        path.restriction = .localNetworkDenied
        XCTAssertEqual(path.description, "等待允许 App 访问本地网络")
    }

    func testScanReportsPendingBeforeNetworkGateAndStartsWhenWiFiReturns() async throws {
        let f = try fixture(ids: ["new"]); defer { f.cleanUp() }
        f.manager.foregroundChanged(true)
        try await wait { f.manager.lastCheckedAt != nil && !f.manager.running }
        XCTAssertEqual(f.manager.pendingCount, 1)
        XCTAssertEqual(f.manager.status, "等待网络连接")
        XCTAssertTrue(f.library.uploaded.isEmpty)
        f.manager.networkChanged(ready: true, wifi: false, expensive: true, constrained: false, cellular: true)
        try await wait { f.manager.status == "等待 Wi-Fi" }
        XCTAssertEqual(f.manager.pendingCount, 1)
        f.manager.networkChanged(ready: true, wifi: true, expensive: false, constrained: true)
        try await wait { f.manager.status == "等待关闭低数据模式" }
        XCTAssertTrue(f.library.uploaded.isEmpty)
        connectWiFi(f.manager)
        try await wait { f.manager.ledger.completed == ["new"] }
        XCTAssertEqual(f.library.uploaded, ["new"])
    }

    func testResourceFailureDoesNotBlockLaterPhotoAndRetryKeepsReceipts() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.library.exportFailures["first"] = PhotoBackupError.original
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "已检查 · 1 张待重试" }
        XCTAssertEqual(f.manager.ledger.completed, ["second"])
        XCTAssertEqual(f.manager.pendingCount, 1)
        XCTAssertEqual(f.library.uploaded, ["second"])
        XCTAssertTrue(f.manager.error?.contains("无法完整读取") == true)
        f.library.exportFailures.removeAll(); f.manager.checkNow()
        try await wait { f.manager.pendingCount == 0 && !f.manager.running }
        XCTAssertEqual(f.library.uploaded, ["second", "first"])
        XCTAssertEqual(try f.file.load().completed, ["first", "second"])
        XCTAssertNil(f.manager.error)
    }

    func testConflictAndVerificationErrorsLeaveOnlyFailedPhotosPending() async throws {
        let f = try fixture(ids: ["conflict", "verification", "good"]); defer { f.cleanUp() }
        f.library.uploadFailures["conflict"] = PhotoBackupError.conflict
        f.library.uploadFailures["verification"] = PhotoBackupError.verification
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "已检查 · 2 张待重试" }
        XCTAssertEqual(f.manager.ledger.completed, ["good"])
        XCTAssertEqual(f.manager.pendingCount, 2)
        XCTAssertEqual(f.library.uploaded, ["good"])
        XCTAssertTrue(f.manager.error?.hasPrefix("2 张照片未完成：") == true)
    }

    func testPhotoKitMissingResourceSkipsOneItemButNetworkFailureStopsBatch() async throws {
        let f = try fixture(ids: ["missing", "network", "later"]); defer { f.cleanUp() }
        f.library.exportFailures["missing"] = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.missingResource.rawValue)
        f.library.exportFailures["network"] = URLError(.notConnectedToInternet)
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "备份未完成" }
        XCTAssertTrue(f.manager.ledger.completed.isEmpty)
        XCTAssertTrue(f.library.uploaded.isEmpty)
        XCTAssertEqual(f.manager.pendingCount, 3)
    }

    func testPersistFailureStopsBatchAndManualCheckReloadsRepairedLedger() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.library.beforeUpload = {
            try FileManager.default.removeItem(at: f.file.url)
            try FileManager.default.createDirectory(at: f.file.url, withIntermediateDirectories: false)
            f.library.beforeUpload = nil
        }
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "备份未完成" }
        XCTAssertEqual(f.library.uploaded, ["first"])
        XCTAssertTrue(f.manager.ledger.completed.isEmpty)
        f.manager.checkNow()
        XCTAssertEqual(f.manager.status, "备份记录暂不可用")
        try FileManager.default.removeItem(at: f.file.url)
        try f.file.save(f.initialLedger)
        f.manager.checkNow()
        try await wait { f.manager.pendingCount == 0 && f.manager.ledger.completed.count == 2 }
        XCTAssertEqual(f.library.uploaded, ["first", "first", "second"])
        XCTAssertNil(f.manager.error)
    }

    func testPermissionAndFatalFailureStopWithoutUploadingAndEmptyScanClearsError() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.library.authorization = .limited
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        XCTAssertEqual(f.manager.status, "等待全部照片权限")
        XCTAssertNil(f.manager.lastCheckedAt)
        f.library.authorization = .authorized
        f.library.exportFailures["first"] = PhotoBackupError.targetChanged
        f.manager.checkNow()
        try await wait { f.manager.status == "备份未完成" }
        XCTAssertTrue(f.library.uploaded.isEmpty)
        f.library.candidates = []; f.manager.checkNow()
        try await wait { f.manager.pendingCount == 0 && f.manager.status == "等待新照片" }
        XCTAssertNil(f.manager.error)
    }
    func testWrongAccountIsNotReportedAsAnEmptySuccessfulBackup() async throws {
        let f = try fixture(ids: [], owner: "another-account"); defer { f.cleanUp() }
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "备份未完成" }
        XCTAssertEqual(f.manager.error, PhotoBackupError.targetChanged.localizedDescription)
        XCTAssertTrue(f.library.uploaded.isEmpty)
    }

    func testSwitchingToCellularCancelsInFlightUploadWithoutReceiptOrLaterPhoto() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.library.suspendUpload = {
            do { try await Task.sleep(for: .seconds(10)) }
            catch is CancellationError { throw URLError(.cancelled) }
        }
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.library.startedUploads == ["first"] }
        XCTAssertTrue(f.manager.running)
        f.manager.networkChanged(ready: true, wifi: false, expensive: true, constrained: false, cellular: true)
        try await wait { f.manager.status == "等待 Wi-Fi" && !f.manager.running }
        XCTAssertTrue(f.manager.ledger.completed.isEmpty)
        XCTAssertTrue(try f.file.load().completed.isEmpty)
        XCTAssertEqual(f.manager.pendingCount, 2)
        XCTAssertEqual(f.library.startedUploads, ["first"])
        XCTAssertTrue(f.library.uploaded.isEmpty)
        XCTAssertNil(f.manager.error)
        // A later permitted route resumes the same queue, with no cancellation backoff.
        f.library.suspendUpload = nil
        connectWiFi(f.manager)
        try await wait { f.manager.ledger.completed.count == 2 && !f.manager.running }
        XCTAssertEqual(f.library.uploaded, ["first", "second"])
    }

    func testURLSessionCancellationPausesWithoutBackoffOrFalseFailure() async throws {
        let f = try fixture(ids: ["first"]); defer { f.cleanUp() }
        f.library.uploadFailures["first"] = URLError(.cancelled)
        connectWiFi(f.manager); f.manager.foregroundChanged(true)
        try await wait { f.manager.status == "等待继续备份" && !f.manager.running }
        XCTAssertNil(f.manager.error)
        XCTAssertTrue(f.manager.ledger.completed.isEmpty)
        f.library.uploadFailures.removeAll()
        // Automatic triggers must recover immediately; checkNow would bypass and
        // conceal an accidental retry backoff, so deliberately do not call it.
        f.manager.requestRun()
        try await wait { f.manager.ledger.completed == ["first"] }
        XCTAssertEqual(f.library.uploaded, ["first"])
    }

}
