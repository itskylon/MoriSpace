import SwiftUI
import Photos
import Network
import BackgroundTasks

@MainActor
final class PhotoBackupManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let taskIdentifier = "dev.kylon.MoriPhotos.new-photo-backup"
    @Published private(set) var ledger = BackupLedger()
    @Published private(set) var status = "未开启"
    @Published private(set) var error: String?
    @Published private(set) var folderError: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    private let file: BackupLedgerFile
    private weak var app: AppState?
    private let monitor = NWPathMonitor()
    private var networkReady = false
    private var unmetered = false
    private var foreground = false
    private var backgroundRun = false
    private var backgroundExpired = false
    private var rescanRequested = false
    private var observing = false
    private var readable = true
    private var runTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private var lease: UIBackgroundTaskIdentifier = .invalid

    init(app: AppState, file: BackupLedgerFile? = nil) {
        self.app = app
        self.file = file ?? Self.defaultFile()
        super.init()
        reloadLedger()
        monitor.pathUpdateHandler = { [weak self] path in
            let ready = path.status == .satisfied
            let wifi = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.networkReady != ready || self.unmetered != wifi
                self.networkReady = ready; self.unmetered = wifi
                if !self.canUseNetwork { self.runTask?.cancel() }
                else if changed { self.nextAttempt = .distantPast; self.requestRun() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.kylon.MoriPhotos.backup-network"))
    }
    private static func defaultFile() -> BackupLedgerFile {
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if NASConnectionFixture.enabled || FileStationFixture.enabled {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoriBackupUITest-ledger.json")
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--reset-nas-connection-fixture") || args.contains("--empty-connection-fixture") || args.contains("--reset-files-fixture") {
                try? FileManager.default.removeItem(at: url)
            }
            return BackupLedgerFile(url: url)
        }
        #endif
        return BackupLedgerFile(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBackup/ledger.json"))
    }
    deinit {
        monitor.cancel(); retryTask?.cancel(); runTask?.cancel()
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }
    var configuration: BackupConfiguration { ledger.configuration }
    var canUseNetwork: Bool { networkReady && (!configuration.wifiOnly || unmetered) }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.requestRun() }
    }
    func foregroundChanged(_ active: Bool) {
        foreground = AppPlatform.isMac || active
        if foreground {
            endLease()
            if !readable { reloadLedger() }
            requestRun()
        } else {
            scheduleBackground()
            #if !targetEnvironment(macCatalyst)
            if running, lease == .invalid {
                lease = UIApplication.shared.beginBackgroundTask(withName: "Finish new photo backup") { [weak self] in
                    Task { @MainActor [weak self] in self?.runTask?.cancel(); self?.endLease() }
                }
            }
            #endif
        }
    }
    private func reloadLedger() {
        do { ledger = try file.load(); readable = true; error = nil; status = configuration.enabled ? "等待检查新照片" : "未开启" }
        catch { readable = false; self.error = PhotoBackupError.ledger.localizedDescription; status = "备份记录暂不可用" }
    }
    private func save(_ next: BackupLedger) throws {
        guard readable else { throw PhotoBackupError.ledger }
        do { try file.save(next); ledger = next }
        catch { readable = false; throw PhotoBackupError.ledger }
    }
    func enable(folder: String, wifiOnly: Bool) async {
        guard !preparing else { return }
        preparing = true; error = nil
        defer { preparing = false; requestRun() }
        do {
            guard readable else { throw PhotoBackupError.ledger }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw PhotoBackupError.fullAccess }
            guard let app, app.hasSavedConnection else { throw PhotoBackupError.connection }
            let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            try NASFile.validatePath(path)
            let owner = app.fileAccountID
            await app.restoreConnection(service: .files, retry: true)
            guard let client = app.fileClient else { throw PhotoBackupError.connection }
            try await client.verifyBackupDestination(path)
            guard owner == app.fileAccountID, client === app.fileClient else { throw PhotoBackupError.targetChanged }
            var next = ledger
            try next.enable(owner: owner, folder: path, wifiOnly: wifiOnly, now: Date())
            try app.setBackupBackgroundAccess(true)
            do { try save(next) } catch { try? app.setBackupBackgroundAccess(false); throw error }
            failures = 0; nextAttempt = .distantPast
            scheduleBackground(); requestRun()
        } catch { self.error = friendlyError(error) }
    }
    func disable() {
        runTask?.cancel(); retryTask?.cancel()
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        #endif
        var next = ledger; next.configuration.enabled = false
        do { try save(next); try app?.setBackupBackgroundAccess(false); error = nil; status = "已关闭" }
        catch { self.error = friendlyError(error) }
    }
    @discardableResult
    func selectFolder(_ path: String, owner: String) async -> Bool {
        guard !preparing else { return false }
        preparing = true; folderError = nil
        defer { preparing = false; requestRun() }
        do {
            guard readable else { throw PhotoBackupError.ledger }
            guard let app, owner == app.fileAccountID, let client = app.fileClient else { throw PhotoBackupError.targetChanged }
            // Finish cancellation before changing receipts, so an old upload cannot mark a new destination complete.
            runTask?.cancel(); retryTask?.cancel()
            await runTask?.value
            try Task.checkCancellation()
            try await client.verifyBackupDestination(path)
            try Task.checkCancellation()
            guard owner == app.fileAccountID, client === app.fileClient else { throw PhotoBackupError.targetChanged }
            var next = ledger
            try next.selectFolder(owner: owner, folder: path, now: Date())
            try save(next)
            error = nil
            pendingCount = 0; failures = 0; nextAttempt = .distantPast
            status = configuration.enabled ? "等待检查新照片" : "备份位置已选好"
            scheduleBackground()
            return true
        } catch {
            folderError = friendlyError(error)
            return false
        }
    }
    func clearFolderError() { folderError = nil }
    func checkNow() { nextAttempt = .distantPast; requestRun() }
    func requestRun() {
        guard configuration.enabled, readable, !preparing, foreground || (backgroundRun && !backgroundExpired) else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            error = PhotoBackupError.fullAccess.localizedDescription; status = "等待全部照片权限"; return
        }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        guard runTask == nil else { rescanRequested = true; return }
        guard Date() >= nextAttempt else { return }
        guard canUseNetwork else { status = networkReady ? "等待 Wi-Fi" : "等待网络连接"; return }
        runTask = Task { [weak self] in await self?.run() }
    }
    private func run() async {
        running = true; error = nil
        defer {
            running = false; runTask = nil; endLease()
            if rescanRequested { rescanRequested = false; requestRun() }
        }
        let owner = configuration.owner, folder = configuration.folder
        do {
            guard let start = configuration.startedAt, let app else { throw PhotoBackupError.connection }
            guard owner == app.fileAccountID else { throw PhotoBackupError.targetChanged }
            let items = ledger.pending(BackupPhotoLibrary.candidates(since: start))
            pendingCount = items.count
            guard !items.isEmpty else { status = ledger.completed.isEmpty ? "等待新照片" : "新照片已全部备份"; failures = 0; return }
            status = "正在连接 NAS"
            await app.restoreConnection(service: .files, retry: true)
            try Task.checkCancellation()
            guard let client = app.fileClient else {
                error = app.restoreErrors[.files]
                throw PhotoBackupError.connection
            }
            for candidate in items {
                try Task.checkCancellation()
                guard canUseNetwork, configuration.enabled else { throw CancellationError() }
                guard owner == app.fileAccountID, folder == configuration.folder, client === app.fileClient else { throw PhotoBackupError.targetChanged }
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw PhotoBackupError.fullAccess }
                status = "正在备份 · 剩余 \(pendingCount) 张"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoriBackup-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                defer { try? FileManager.default.removeItem(at: directory) }
                let resources = try await BackupPhotoLibrary.originals(for: candidate, directory: directory, allowCloud: true)
                let target = folder + "/" + BackupPhotoLibrary.monthFolder(for: candidate.created)
                for original in resources {
                    try Task.checkCancellation()
                    guard canUseNetwork, configuration.enabled, owner == app.fileAccountID, client === app.fileClient else { throw CancellationError() }
                    try await client.uploadBackupOriginal(original, folder: target, wifiOnly: configuration.wifiOnly)
                }
                try Task.checkCancellation()
                var next = ledger; next.completed.insert(candidate.id); next.lastCompletedAt = Date()
                try save(next)
                pendingCount -= 1
            }
            failures = 0; nextAttempt = .distantPast; status = "新照片已全部备份"
        } catch is CancellationError {
            status = configuration.enabled ? "等待继续备份" : "已关闭"
        } catch {
            if self.error == nil { self.error = friendlyError(error) }
            status = "备份未完成"
            failures += 1
            nextAttempt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(min(failures - 1, 6)))))
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(max(1, nextAttempt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }; requestRun()
            }
        }
    }
    func scheduleBackground() {
        #if !targetEnvironment(macCatalyst)
        guard configuration.enabled, readable else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Foreground catch-up remains available when iOS disables background refresh. */ }
        #endif
    }
    func performBackground(_ task: BGTask) async {
        backgroundRun = true
        backgroundExpired = false
        task.expirationHandler = { [weak self] in Task { @MainActor in
            self?.backgroundExpired = true; self?.runTask?.cancel()
        } }
        if !readable { reloadLedger() }
        // Allow NWPathMonitor to deliver its initial route after a background launch.
        for _ in 0..<10 where !networkReady { try? await Task.sleep(for: .milliseconds(100)) }
        if !backgroundExpired { requestRun() }
        await runTask?.value
        backgroundRun = false
        task.setTaskCompleted(success: !backgroundExpired && error == nil && pendingCount == 0)
        scheduleBackground()
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
}

final class BackupAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static weak var manager: PhotoBackupManager?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PhotoBackupManager.taskIdentifier, using: .main) { task in
            Task { @MainActor in
                guard let manager = Self.manager else { task.setTaskCompleted(success: false); return }
                await manager.performBackground(task)
            }
        }
        #endif
        return true
    }
}
