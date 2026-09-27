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
    let allowsImport: Bool
    let isFixture: Bool

    private let cache: UsageWidgetCache
    private let now: () -> Date
    private let reloadWidgets: () -> Void
    private let localReader: (() async throws -> UsageWidgetSnapshot)?
    private var localTask: Task<Void, Never>?
    private var localGeneration = UUID()
    private var hasDisplayedRecord = false

    init(cache: UsageWidgetCache = .shared, allowsImport: Bool = !AppPlatform.isMac,
         now: @escaping () -> Date = { Date() },
         useLocalHelper: Bool = AppPlatform.isMac,
         localReader: (() async throws -> UsageWidgetSnapshot)? = nil,
         reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetConstants.kind) }) {
        self.cache = cache
        self.allowsImport = allowsImport
        self.now = now
        self.reloadWidgets = reloadWidgets
        if let localReader { self.localReader = localReader }
        else if useLocalHelper { self.localReader = { try await UsageLocalClient.fetch() } }
        else { self.localReader = nil }
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        isFixture = ProcessInfo.processInfo.arguments.contains("--usage-widget-fixture")
        #else
        isFixture = false
        #endif
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

    /// Reads the local helper's existing record, never triggers a new Codex quota request.
    func reload() {
        guard !isFixture else { return }
        readCachedRecord()
        guard let localReader else { return }
        localTask?.cancel()
        let generation = UUID()
        localGeneration = generation
        refreshing = true
        localTask = Task { [weak self] in
            do {
                let next = try await localReader()
                try Task.checkCancellation()
                guard let self, self.localGeneration == generation else { return }
                _ = try next.validated(now: self.now())
                guard next.status == .ready else { throw UsageLocalClientError.unavailableRecord }
                // A late helper response must not replace a newer record already displayed.
                if self.snapshot.windows.isEmpty || next.fetchedAt >= self.snapshot.fetchedAt {
                    let retained = try self.cache.write(next, now: self.now())
                    self.replaceDisplayedSnapshot(retained)
                }
                self.error = nil
            } catch {
                guard let self, self.localGeneration == generation, !Task.isCancelled else { return }
                self.error = "未能读取本机额度助手，请确认助手已启用且 Codex 已登录。仍保留上次记录，采集时间没有变化。"
            }
            guard let self, self.localGeneration == generation else { return }
            self.refreshing = false
            self.localTask = nil
        }
    }

    private func readCachedRecord() {
        guard let url = cache.fileURL else {
            error = "无法访问共享记录，请检查此版本的小组件签名与 App Groups 配置。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Keep an already displayed good record if the helper's file is temporarily missing.
            if snapshot.windows.isEmpty { error = nil }
            else { error = "最新记录暂不可用，仍显示上次读取的数据。" }
            return
        }
        do {
            let next = try UsageWidgetSnapshot.decode(Self.readRecord(at: url), now: now())
            replaceDisplayedSnapshot(next)
            error = nil
        } catch {
            self.error = "读取额度记录失败，已保留上次数据。请等待读取助手更新，或重新导入有效的 JSON 记录。"
        }
    }

    func importSnapshot(from url: URL) async {
        guard allowsImport else {
            error = "Mac 的额度记录由本机读取助手维护，不能用导入文件覆盖。"
            return
        }
        guard !importing, !isFixture else { return }
        importing = true; error = nil; importNotice = nil
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Copy bytes before writing the cache, including when the selected URL has the same name.
            let data = try await Task.detached(priority: .userInitiated) { try Self.readRecord(at: url) }.value
            try Task.checkCancellation()
            let next = try UsageWidgetSnapshot.decode(data, now: now())
            let retained = try cache.write(next, now: now())
            replaceDisplayedSnapshot(retained)
            importNotice = retained.fetchedAt > next.fetchedAt ? "这份记录较旧，已保留更新的记录。" : "已导入记录，非实时同步。"
        } catch {
            self.error = "导入失败：请选择有效的森空间额度 JSON 记录（版本 1，最大 1 MB）。已保留原有数据。"
        }
    }

    /// Re-encodes the allowlisted model only; preserves the collector's timestamps verbatim.
    func exportData() throws -> Data {
        try snapshot.encoded(now: now())
    }

    func reportFileError(_ message: String) { error = message }

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

    nonisolated private static func readRecord(at url: URL) throws -> Data {
        let maximumRecordBytes = UsageWidgetConstants.maximumFileSize
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
