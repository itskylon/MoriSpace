import SwiftUI
import Photos
import Network
import BackgroundTasks

enum PhotoBackupNetworkRestriction {
    case wifiDenied, cellularDenied, localNetworkDenied
    var message: String {
        switch self {
        case .wifiDenied: return "等待允许 App 使用 Wi-Fi"
        case .cellularDenied: return "等待允许 App 使用移动数据或连接 Wi-Fi"
        case .localNetworkDenied: return "等待允许 App 访问本地网络"
        }
    }
}

struct PhotoBackupNetworkPolicy: Equatable {
    var ready = false
    var usesWiFiOrEthernet = false
    var usesCellular = false
    var expensive = false
    var constrained = false
    var wifiAvailable = false
    var ethernetAvailable = false
    var restriction: PhotoBackupNetworkRestriction?

    func permitsUpload(wifiOnly: Bool) -> Bool {
        guard ready else { return false }
        guard wifiOnly else { return true }
        return !usesCellular && !expensive && !constrained
            && (usesWiFiOrEthernet || wifiAvailable || ethernetAvailable)
    }
    func waitingReason(wifiOnly: Bool) -> String? {
        if !ready { return restriction?.message ?? "等待网络连接" }
        if wifiOnly && constrained { return "等待关闭低数据模式" }
        if !permitsUpload(wifiOnly: wifiOnly) { return "等待 Wi-Fi" }
        return nil
    }
    var description: String {
        if !ready { return restriction?.message ?? "当前网络不可用" }
        if constrained { return "当前网络开启了低数据模式" }
        if usesCellular || expensive { return "当前为移动网络或计费网络" }
        if usesWiFiOrEthernet { return "Wi-Fi 或有线网络已连接" }
        if wifiAvailable || ethernetAvailable { return "已检测到可用的 Wi-Fi 或有线网络" }
        return "当前路由尚未确认 Wi-Fi，可能受 VPN 影响"
    }
}

// The default operations use PhotoKit and the authenticated File Station client.
// Tests replace these boundaries without reading a real library or contacting a NAS.
@MainActor
struct PhotoBackupOperations {
    var authorization: () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    var candidates: (Date) -> [BackupCandidate] = { BackupPhotoLibrary.candidates(since: $0) }
    var originals: (BackupCandidate, URL) async throws -> [BackupOriginal] = {
        try await BackupPhotoLibrary.originals(for: $0, directory: $1, allowCloud: true)
    }
    var upload: (SynologyClient, BackupOriginal, String, Bool) async throws -> Void = {
        try await $0.uploadBackupOriginal($1, folder: $2, wifiOnly: $3)
    }
}

@MainActor
final class PhotoBackupManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let taskIdentifier = "dev.kylon.MoriPhotos.new-photo-backup"
    @Published private(set) var ledger = BackupLedger()
    @Published private(set) var status = "未开启"
    @Published private(set) var error: String?
    @Published private(set) var folderError: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var networkStatus = "正在检查网络"
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    private let file: BackupLedgerFile
    private let operations: PhotoBackupOperations
    private let observesSystemChanges: Bool
    private weak var app: AppState?
    private let monitor = NWPathMonitor()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let ethernetMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private var network = PhotoBackupNetworkPolicy()
    private var networkReady: Bool { network.ready }
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

    init(app: AppState, file: BackupLedgerFile? = nil, operations: PhotoBackupOperations? = nil, observesSystemChanges: Bool = true) {
        self.app = app
        self.file = file ?? Self.defaultFile()
        self.operations = operations ?? PhotoBackupOperations()
        self.observesSystemChanges = observesSystemChanges
        super.init()
        reloadLedger()
        if observesSystemChanges {
            monitor.pathUpdateHandler = { [weak self] path in
                let ready = path.status == .satisfied
                let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                let expensive = path.isExpensive, constrained = path.isConstrained
                let restriction: PhotoBackupNetworkRestriction?
                if !ready {
                    switch path.unsatisfiedReason {
                    case .wifiDenied: restriction = .wifiDenied
                    case .cellularDenied: restriction = .cellularDenied
                    case .localNetworkDenied: restriction = .localNetworkDenied
                    default: restriction = nil
                    }
                } else { restriction = nil }
                Task { @MainActor [weak self] in
                    self?.networkChanged(ready: ready, wifi: wifi, expensive: expensive, constrained: constrained, cellular: path.usesInterfaceType(.cellular), restriction: restriction)
                }
            }
            let queue = DispatchQueue(label: "dev.kylon.MoriPhotos.backup-network")
            for (interfaceMonitor, isWiFi) in [(wifiMonitor, true), (ethernetMonitor, false)] {
                interfaceMonitor.pathUpdateHandler = { [weak self] path in
                    let available = path.status == .satisfied && !path.isExpensive && !path.isConstrained
                    Task { @MainActor [weak self] in self?.localInterfaceChanged(wifi: isWiFi, available: available) }
                }
                interfaceMonitor.start(queue: queue)
            }
            monitor.start(queue: queue)
        }
    }
    func networkChanged(ready: Bool, wifi: Bool, expensive: Bool, constrained: Bool, cellular: Bool = false, restriction: PhotoBackupNetworkRestriction? = nil) {
        var next = network
        next.ready = ready; next.usesWiFiOrEthernet = wifi; next.usesCellular = cellular
        next.expensive = expensive; next.constrained = constrained; next.restriction = ready ? nil : restriction
        updateNetwork(next)
    }
    private func localInterfaceChanged(wifi: Bool, available: Bool) {
        var next = network
        if wifi { next.wifiAvailable = available } else { next.ethernetAvailable = available }
        updateNetwork(next)
    }
    private func updateNetwork(_ next: PhotoBackupNetworkPolicy) {
        let changed = network != next
        network = next; networkStatus = next.description
        if !canUseNetwork { runTask?.cancel() }
        if changed { nextAttempt = .distantPast; requestRun() }
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
        monitor.cancel(); wifiMonitor.cancel(); ethernetMonitor.cancel(); retryTask?.cancel(); runTask?.cancel()
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }
    var configuration: BackupConfiguration { ledger.configuration }
    var canUseNetwork: Bool { network.permitsUpload(wifiOnly: configuration.wifiOnly) }
    private var networkWaitingStatus: String? { network.waitingReason(wifiOnly: configuration.wifiOnly) }
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
            guard operations.authorization() == .authorized else { throw PhotoBackupError.fullAccess }
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
    func checkNow() {
        if !readable { reloadLedger() }
        nextAttempt = .distantPast
        requestRun()
    }
    func requestRun() {
        guard readable else { error = PhotoBackupError.ledger.localizedDescription; status = "备份记录暂不可用"; return }
        guard configuration.enabled else { status = "未开启自动备份"; return }
        guard !preparing else { status = "正在检查备份位置…"; return }
        guard foreground || (backgroundRun && !backgroundExpired) else { status = "等待打开 App 继续检查"; return }
        guard operations.authorization() == .authorized else {
            error = PhotoBackupError.fullAccess.localizedDescription; status = "等待全部照片权限"; return
        }
        if observesSystemChanges && !observing { PHPhotoLibrary.shared().register(self); observing = true }
        guard runTask == nil else { rescanRequested = true; return }
        // Scan locally even if the upload must wait for an eligible network.
        runTask = Task { [weak self] in await self?.run() }
    }
    private func run() async {
        running = true
        defer {
            running = false; runTask = nil; endLease()
            if rescanRequested { rescanRequested = false; requestRun() }
        }
        let owner = configuration.owner, folder = configuration.folder
        do {
            try Task.checkCancellation()
            guard let start = configuration.startedAt, let app else { throw PhotoBackupError.connection }
            let items = ledger.pending(operations.candidates(start))
            pendingCount = items.count; lastCheckedAt = Date()
            guard owner == app.fileAccountID else { throw PhotoBackupError.targetChanged }
            guard !items.isEmpty else {
                error = nil; status = ledger.completed.isEmpty ? "等待新照片" : "新照片已全部备份"
                failures = 0; nextAttempt = .distantPast; retryTask?.cancel()
                return
            }
            if let waiting = networkWaitingStatus { error = nil; status = waiting; return }
            guard Date() >= nextAttempt else { status = "等待重试 · 剩余 \(pendingCount) 张"; return }
            error = nil; status = "正在连接 NAS"
            await app.restoreConnection(service: .files, retry: true)
            try Task.checkCancellation()
            guard let client = app.fileClient else {
                error = app.restoreErrors[.files]
                throw PhotoBackupError.connection
            }
            var failedCount = 0
            var firstItemError: String?
            for candidate in items {
                try Task.checkCancellation()
                guard canUseNetwork, configuration.enabled else { throw CancellationError() }
                guard owner == app.fileAccountID, folder == configuration.folder, client === app.fileClient else { throw PhotoBackupError.targetChanged }
                guard operations.authorization() == .authorized else { throw PhotoBackupError.fullAccess }
                status = "正在备份 · 剩余 \(pendingCount) 张"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoriBackup-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                defer { try? FileManager.default.removeItem(at: directory) }
                do {
                    let resources = try await operations.originals(candidate, directory)
                    guard !resources.isEmpty else { throw PhotoBackupError.original }
                    let target = folder + "/" + BackupPhotoLibrary.monthFolder(for: candidate.created)
                    for original in resources {
                        try Task.checkCancellation()
                        guard canUseNetwork, configuration.enabled else { throw CancellationError() }
                        guard owner == app.fileAccountID, folder == configuration.folder, client === app.fileClient else { throw PhotoBackupError.targetChanged }
                        guard operations.authorization() == .authorized else { throw PhotoBackupError.fullAccess }
                        try await operations.upload(client, original, target, configuration.wifiOnly)
                    }
                } catch {
                    try Task.checkCancellation()
                    guard operations.authorization() == .authorized else { throw PhotoBackupError.fullAccess }
                    guard Self.isRecoverableItemError(error) else { throw error }
                    failedCount += 1
                    if firstItemError == nil { firstItemError = Self.itemErrorMessage(error) }
                    continue
                }
                try Task.checkCancellation()
                // Never issue a receipt after an account, destination or permission change.
                guard owner == app.fileAccountID, folder == configuration.folder, client === app.fileClient else { throw PhotoBackupError.targetChanged }
                guard operations.authorization() == .authorized else { throw PhotoBackupError.fullAccess }
                var next = ledger; next.completed.insert(candidate.id); next.lastCompletedAt = Date()
                try save(next)
                pendingCount -= 1
            }
            if let firstItemError {
                error = "\(failedCount) 张照片未完成：" + firstItemError
                status = "已检查 · \(failedCount) 张待重试"
                scheduleRetry()
            } else {
                error = nil; failures = 0; nextAttempt = .distantPast; status = "新照片已全部备份"
            }
        } catch is CancellationError {
            status = configuration.enabled ? networkWaitingStatus ?? "等待继续备份" : "已关闭"
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                status = configuration.enabled ? networkWaitingStatus ?? "等待继续备份" : "已关闭"
                return
            }
            if self.error == nil { self.error = friendlyError(error) }
            status = "备份未完成"
            scheduleRetry()
        }
    }
    private static func isRecoverableItemError(_ error: Error) -> Bool {
        if let backupError = error as? PhotoBackupError {
            switch backupError {
            case .original, .conflict, .verification: return true
            default: return false
            }
        }
        // Only resource-specific PhotoKit errors may be skipped. Network, access,
        // library availability and local-disk failures must still pause the batch.
        let ns = error as NSError
        guard ns.domain == PHPhotosErrorDomain else { return false }
        return [PHPhotosError.identifierNotFound.rawValue, PHPhotosError.invalidResource.rawValue,
                PHPhotosError.missingResource.rawValue, PHPhotosError.requestNotSupportedForAsset.rawValue].contains(ns.code)
    }
    private static func itemErrorMessage(_ error: Error) -> String {
        (error as NSError).domain == PHPhotosErrorDomain ? PhotoBackupError.original.localizedDescription : friendlyError(error)
    }
    private func scheduleRetry() {
        failures += 1
        nextAttempt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(min(failures - 1, 6)))))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(1, nextAttempt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }; requestRun()
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
