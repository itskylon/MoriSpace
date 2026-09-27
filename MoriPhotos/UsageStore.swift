import Foundation
import SwiftUI
import WidgetKit

/// Reads only the small, sanitized widget record. Codex authentication belongs to the local helper.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageWidgetSnapshot
    @Published private(set) var error: String?
    @Published private(set) var importing = false
    @Published private(set) var refreshing = false
    @Published private(set) var importNotice: String?
    @Published private(set) var remoteConfiguration: UsageRemoteConfiguration?
    var syncEnabled: Bool { remoteConfiguration != nil }
    var syncHost: String? { remoteConfiguration.flatMap { URL(string: $0.baseURL)?.host } }
    var hasPendingRemoteConfiguration: Bool {
        resolvedPendingConfigurationURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    let allowsImport: Bool
    let isFixture: Bool

    private let cache: UsageWidgetCache
    private let now: () -> Date
    private let reloadWidgets: () -> Void
    private let localReader: (() async throws -> UsageWidgetSnapshot)?
    private let configurationLoad: () throws -> UsageRemoteConfiguration?
    private let configurationSave: (UsageRemoteConfiguration) throws -> Void
    private let configurationDelete: () throws -> Void
    private let remoteFetch: (UsageRemoteConfiguration) async throws -> UsageWidgetSnapshot
    private let pendingConfigurationURL: URL?
    private var localTask: Task<Void, Never>?
    private var localGeneration = UUID()
    private var operationGeneration = UUID()
    private var operationError: String?
    private var hasDisplayedRecord = false

    init(cache: UsageWidgetCache = .shared, allowsImport: Bool = !AppPlatform.isMac,
         now: @escaping () -> Date = { Date() },
         useLocalHelper: Bool = AppPlatform.isMac,
         useRemoteSync: Bool = !AppPlatform.isMac,
         localReader: (() async throws -> UsageWidgetSnapshot)? = nil,
         configurationLoad: @escaping () throws -> UsageRemoteConfiguration? = UsageRemoteKeychain.load,
         configurationSave: @escaping (UsageRemoteConfiguration) throws -> Void = UsageRemoteKeychain.save,
         configurationDelete: @escaping () throws -> Void = UsageRemoteKeychain.delete,
         remoteFetch: @escaping (UsageRemoteConfiguration) async throws -> UsageWidgetSnapshot = { try await UsageRemoteClient.fetch(configuration: $0) },
         pendingConfigurationURL: URL? = nil,
         reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetConstants.kind) }) {
        self.cache = cache
        self.allowsImport = allowsImport
        self.now = now
        self.reloadWidgets = reloadWidgets
        self.configurationLoad = configurationLoad
        self.configurationSave = configurationSave
        self.configurationDelete = configurationDelete
        self.remoteFetch = remoteFetch
        self.pendingConfigurationURL = pendingConfigurationURL
        if let localReader { self.localReader = localReader }
        else if useLocalHelper { self.localReader = { try await UsageLocalClient.fetch() } }
        else { self.localReader = nil }
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        isFixture = ProcessInfo.processInfo.arguments.contains("--usage-widget-fixture")
        #else
        isFixture = false
        #endif
        if useRemoteSync && !isFixture { remoteConfiguration = try? configurationLoad() }
        if isFixture {
            let date = now()
            snapshot = UsageWidgetSnapshot(version: 1, fetchedAt: date, validUntil: date.addingTimeInterval(900), status: .ready, windows: [
                UsageWidgetWindow(id: "primary", label: "5 小时", usedPercent: 18, windowMinutes: 300, resetsAt: date.addingTimeInterval(3 * 3600)),
                UsageWidgetWindow(id: "secondary", label: "每周", usedPercent: 36, windowMinutes: 10_080, resetsAt: date.addingTimeInterval(4 * 24 * 3600))
            ])
        } else {
            snapshot = .empty(.notConnected, now: now())
        }
        #if DEBUG && targetEnvironment(simulator)
        if isFixture {
            do { try cache.write(snapshot, now: now()); reloadWidgets() }
            catch { self.error = "预览数据可显示，但未能写入模拟器的小组件共享记录。" }
        }
        #endif
    }

    /// Reads the latest collected record locally or over the configured HTTPS relay.
    func reload() {
        guard !isFixture, !importing else { return }
        readCachedRecord()
        let reader: (() async throws -> UsageWidgetSnapshot)?
        let requestedConfiguration = localReader == nil ? remoteConfiguration : nil
        let isRemote = requestedConfiguration != nil
        if let localReader { reader = localReader }
        else if let configuration = remoteConfiguration {
            let fetch = remoteFetch
            reader = { try await fetch(configuration) }
        } else { reader = nil }
        guard let reader else { return }
        localTask?.cancel()
        let generation = UUID()
        localGeneration = generation
        refreshing = true
        localTask = Task { [weak self] in
            do {
                let next = try await reader()
                try Task.checkCancellation()
                guard let self, self.localGeneration == generation else { return }
                _ = try next.validated(now: self.now())
                guard next.status == .ready else { throw UsageLocalClientError.unavailableRecord }
                // A late helper response must not replace a newer record already displayed.
                if self.snapshot.windows.isEmpty || next.fetchedAt >= self.snapshot.fetchedAt {
                    let retained: UsageWidgetSnapshot
                    if let requestedConfiguration {
                        retained = try UsageRemoteTransaction.withLock(cache: self.cache) {
                            guard try self.configurationLoad() == requestedConfiguration else { throw UsageStoreConnectionError.changed }
                            return try self.cache.write(next, now: self.now())
                        }
                    } else { retained = try self.cache.write(next, now: self.now()) }
                    self.replaceDisplayedSnapshot(retained)
                }
                self.error = self.operationError
            } catch {
                guard let self, self.localGeneration == generation, !Task.isCancelled else { return }
                self.error = self.operationError ?? (isRemote
                    ? "自动同步暂未成功，请检查网络或同步服务。仍保留上次记录，采集时间没有变化。"
                    : "未能读取本机额度助手，请确认助手已启用且 Codex 已登录。仍保留上次记录，采集时间没有变化。")
            }
            guard let self, self.localGeneration == generation else { return }
            self.refreshing = false
            self.localTask = nil
        }
    }

    /// A one-time connection file contains only a relay URL and its read-only credential.
    @discardableResult
    func connectRemote(from url: URL) async -> Bool {
        await connectRemoteRecord(from: url) != nil
    }

    private func connectRemoteRecord(from url: URL) async -> Data? {
        guard allowsImport, !importing, !isFixture else { return nil }
        cancelRefresh()
        let generation = UUID()
        operationGeneration = generation
        importing = true; setOperationError(nil); importNotice = nil
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Self.readRecord(at: url, limit: UsageRemoteConfiguration.maximumFileSize)
            }.value
            let configuration = try UsageRemoteConfiguration.decode(data)
            let fresh = try await remoteFetch(configuration)
            try Task.checkCancellation()
            guard generation == operationGeneration else { return nil }
            _ = try fresh.validated(now: now())
            guard fresh.status == .ready else { throw UsageLocalClientError.unavailableRecord }
            let retained = try UsageRemoteTransaction.withLock(cache: cache) {
                let previousConfiguration = try configurationLoad()
                let previous = cachedRecordForRollback()
                do {
                    // Remove old-source quota before publishing a different credential to the widget.
                    if previousConfiguration != configuration { try cache.remove() }
                    try configurationSave(configuration)
                    return try cache.write(fresh, now: now())
                } catch {
                    restoreConnection(previousConfiguration, snapshot: previous)
                    throw error
                }
            }
            remoteConfiguration = configuration
            hasDisplayedRecord = false
            replaceDisplayedSnapshot(retained)
            importNotice = "自动同步已连接，之后无需手动导入额度。"
            return data
        } catch {
            guard generation == operationGeneration else { return nil }
            setOperationError(Self.connectionFailureMessage(error))
            return nil
        }
    }

    /// Import only after a provisioning link or explicit connect action. Never remove a newer
    /// replacement file, a skipped import, or an unsuccessfully consumed credential.
    func connectPendingRemote() async {
        guard let file = resolvedPendingConfigurationURL, FileManager.default.fileExists(atPath: file.path) else {
            if syncEnabled {
                setOperationError(nil)
                importNotice = "自动同步已连接，正在读取最新记录。"
                reload()
            } else {
                setOperationError("没有找到连接文件。请点“连接自动同步”重新选择同步配置文件。")
            }
            return
        }
        guard let consumed = await connectRemoteRecord(from: file) else { return }
        do {
            guard try Self.readRecord(at: file, limit: UsageRemoteConfiguration.maximumFileSize) == consumed else { return }
            try FileManager.default.removeItem(at: file)
        } catch {
            setOperationError("同步已连接，但一次性连接文件未能清理，请从本机文件中移除该连接文件。")
        }
    }

    func disconnectRemote() {
        cancelRefresh()
        operationGeneration = UUID()
        do {
            try UsageRemoteTransaction.withLock(cache: cache) {
                let previousConfiguration = try configurationLoad()
                let previous = cachedRecordForRollback()
                do {
                    // If quota cannot be cleared, leave the original connection intact.
                    try cache.remove()
                    try configurationDelete()
                } catch {
                    restoreConnection(previousConfiguration, snapshot: previous)
                    throw error
                }
            }
            remoteConfiguration = nil
            snapshot = .empty(.notConnected, now: now()); hasDisplayedRecord = false
            importNotice = "已停止此设备的自动同步。"; setOperationError(nil)
            reloadWidgets()
        } catch { setOperationError("未能完整清除同步连接，请重试。") }
    }

    private func cachedRecordForRollback() -> UsageWidgetSnapshot? {
        guard let url = cache.fileURL, let data = try? Self.readRecord(at: url) else { return nil }
        return try? UsageWidgetSnapshot.decode(data, now: now())
    }

    /// Called only inside the configuration lock. Do not restore old-source quota
    /// unless the corresponding credential was successfully restored too.
    private func restoreConnection(_ previous: UsageRemoteConfiguration?, snapshot previousSnapshot: UsageWidgetSnapshot?) {
        do {
            if try configurationLoad() != previous {
                if let previous { try configurationSave(previous) }
                else { try configurationDelete() }
            }
            guard try configurationLoad() == previous else { throw UsageStoreConnectionError.changed }
            try cache.remove()
            if let previousSnapshot { try cache.write(previousSnapshot, now: now()) }
        } catch {
            // Fail closed rather than label an old account's quota with a new connection.
            try? cache.remove()
            remoteConfiguration = try? configurationLoad()
            snapshot = .empty(.notConnected, now: now()); hasDisplayedRecord = false
            reloadWidgets()
        }
    }

    private func readCachedRecord() {
        guard let url = cache.fileURL else {
            error = operationError ?? "无法访问共享记录，请检查此版本的小组件签名与 App Groups 配置。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Keep an already displayed good record if the helper's file is temporarily missing.
            error = operationError ?? (snapshot.windows.isEmpty ? nil : "最新记录暂不可用，仍显示上次读取的数据。")
            return
        }
        do {
            let next = try UsageWidgetSnapshot.decode(Self.readRecord(at: url), now: now())
            replaceDisplayedSnapshot(next)
            error = operationError
        } catch {
            self.error = operationError ?? "读取额度记录失败，已保留上次数据。请等待读取助手更新，或重新导入有效的 JSON 记录。"
        }
    }

    func importSnapshot(from url: URL) async {
        guard allowsImport else {
            setOperationError("Mac 的额度记录由本机读取助手维护，不能用导入文件覆盖。")
            return
        }
        guard !importing, !isFixture else { return }
        guard remoteConfiguration == nil else {
            setOperationError("请先停止自动同步，再导入离线额度记录。")
            return
        }
        cancelRefresh()
        let generation = UUID()
        operationGeneration = generation
        importing = true; setOperationError(nil); importNotice = nil
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Copy bytes before writing the cache, including when the selected URL has the same name.
            let data = try await Task.detached(priority: .userInitiated) { try Self.readRecord(at: url) }.value
            try Task.checkCancellation()
            let next = try UsageWidgetSnapshot.decode(data, now: now())
            guard generation == operationGeneration else { return }
            let retained = try cache.write(next, now: now())
            replaceDisplayedSnapshot(retained)
            importNotice = retained.fetchedAt > next.fetchedAt ? "这份记录较旧，已保留更新的记录。" : "已导入记录，非实时同步。"
        } catch {
            guard generation == operationGeneration else { return }
            setOperationError("导入失败：请选择有效的森空间额度 JSON 记录（版本 1，最大 1 MB）。已保留原有数据。")
        }
    }

    /// Re-encodes the allowlisted model only; preserves the collector's timestamps verbatim.
    func exportData() throws -> Data {
        try snapshot.encoded(now: now())
    }

    func reportFileError(_ message: String) { setOperationError(message) }

    private func setOperationError(_ message: String?) {
        operationError = message
        error = message
    }

    private var resolvedPendingConfigurationURL: URL? {
        pendingConfigurationURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoriSpace-Usage-Connection.json")
    }

    private static func connectionFailureMessage(_ error: Error) -> String {
        if let known = error as? UsageRemoteError { return "连接失败：" + known.localizedDescription }
        if let network = error as? URLError {
            let reason: String
            switch network.code {
            case .timedOut: reason = "同步服务响应超时"
            case .notConnectedToInternet, .networkConnectionLost: reason = "网络暂不可用"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: reason = "HTTPS 安全连接或证书验证失败"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: reason = "无法连接同步服务器"
            default: reason = "网络请求未完成"
            }
            return "连接失败：\(reason)（代码 \(network.code.rawValue)）。请检查网络与服务状态后重试。"
        }
        return "未能连接同步服务。请检查连接文件、网络与服务状态后重试。"
    }

    /// View lifecycle changes stop polling, not an explicit connection/import transaction.
    func cancelRefresh() {
        localGeneration = UUID()
        localTask?.cancel(); localTask = nil
        refreshing = false
    }

    deinit { localTask?.cancel() }

    private func replaceDisplayedSnapshot(_ next: UsageWidgetSnapshot) {
        guard !hasDisplayedRecord || next.fetchedAt >= snapshot.fetchedAt else { return }
        hasDisplayedRecord = true
        guard next != snapshot else { return }
        snapshot = next
        reloadWidgets()
    }

    nonisolated private static func readRecord(at url: URL, limit maximumRecordBytes: Int = UsageWidgetConstants.maximumFileSize) throws -> Data {
        // Query the path each time; URL resource values can cache metadata across an atomic replacement.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = (values[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumRecordBytes else { throw UsageRecordError.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumRecordBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumRecordBytes else { throw UsageRecordError.invalidSize }
        return data
    }
}

private enum UsageRecordError: Error { case invalidSize }

private enum UsageStoreConnectionError: Error { case changed }
