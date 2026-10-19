import Foundation

struct GoogleDriveDownload: Codable, Identifiable {
    let id: UUID
    let owner: String
    var file: GoogleDriveFile
    let created: Date
    var state: NASDownload.State = .queued
    var received: Int64 = 0
    var expected: Int64?
    var message: String?
    var active: Bool { state == .queued || state == .downloading }
    var localName: String {
        var name = (file.name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "_")
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        if let format = file.exportFormat, !(name as NSString).pathExtension.lowercased().elementsEqual(format.fileExtension) {
            name += "." + format.fileExtension
        }
        let ext = (name as NSString).pathExtension
        let suffix = ext.utf8.count <= 24 && !ext.isEmpty ? "." + ext : ""
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > 220 { stem.removeLast() }
        return stem + suffix
    }
}

@MainActor final class GoogleDriveDownloads: ObservableObject {
    @Published private(set) var records: [GoogleDriveDownload] = []
    @Published var error: String?
    private let directory: URL
    private var loaded = false
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var clients: [String: GoogleDriveClient] = [:]
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoogleDriveDownloads", isDirectory: true)
        reloadIfNeeded()
    }
    func reloadIfNeeded() {
        guard !loaded, jobs.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            let manifest = directory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                records = try JSONDecoder().decode([GoogleDriveDownload].self, from: Data(contentsOf: manifest))
                for index in records.indices {
                    if records[index].active { records[index].state = .failed; records[index].message = "上次下载已中断，连接 Google Drive 后可重新下载。" }
                    if records[index].state == .completed && !FileManager.default.fileExists(atPath: fileURL(records[index]).path) {
                        records[index].state = .failed; records[index].message = "本地文件已不存在，请重新下载。"
                    }
                }
            }
            loaded = true; error = nil; persist()
        } catch { self.error = "无法读取 Google Drive 下载记录；现有记录已保留。" }
    }
    func fileURL(_ record: GoogleDriveDownload) -> URL {
        directory.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.localName)
    }
    func enqueue(_ file: GoogleDriveFile, owner: String, client: GoogleDriveClient) {
        reloadIfNeeded()
        guard loaded, !owner.isEmpty, client.accountID == owner, file.canDownload,
              !records.contains(where: { $0.owner == owner && $0.file.id == file.id && $0.active }) else { return }
        records.insert(.init(id: UUID(), owner: owner, file: file, created: Date(), expected: file.exportFormat == nil ? file.size : nil), at: 0)
        clients[owner] = client; persist(); pump()
    }
    func retry(_ record: GoogleDriveDownload, client: GoogleDriveClient, owner: String) {
        guard record.owner == owner, client.accountID == owner,
              let index = records.firstIndex(where: { $0.id == record.id }), !records[index].active,
              records[index].owner == owner, records[index].state != .completed, jobs[record.id] == nil else { return }
        records[index].state = .queued; records[index].received = 0; records[index].message = nil
        clients[owner] = client; persist(); pump()
    }
    func cancel(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].active else { return }
        records[index].state = .cancelled; records[index].message = nil
        jobs[id]?.cancel(); persist(); pump()
    }
    func cancelActive(owner: String) {
        clients[owner] = nil
        for index in records.indices where records[index].owner == owner && records[index].active {
            records[index].state = .cancelled; records[index].message = "Google 连接已断开，可重新连接后重试。"
            jobs[records[index].id]?.cancel()
        }
        persist()
    }
    func remove(_ record: GoogleDriveDownload) {
        guard !record.active, jobs[record.id] == nil else { return }
        do {
            let folder = directory.appendingPathComponent(record.id.uuidString)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            records.removeAll { $0.id == record.id }; persist()
        } catch { self.error = "无法移除本机下载，请重试。" }
    }
    private func pump() {
        for record in records.reversed() where jobs.count < 2 && record.state == .queued {
            guard let client = clients[record.owner], jobs[record.id] == nil else { continue }
            let id = record.id
            update(id) { $0.state = .downloading }
            jobs[id] = Task { [weak self] in
                guard let self else { return }
                await run(record, client: client)
                jobs[id] = nil; persist(); pump()
            }
        }
    }
    private func run(_ record: GoogleDriveDownload, client: GoogleDriveClient) async {
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let current = try await client.fileInfo(id: record.file.id)
            try Task.checkCancellation()
            guard current.canDownload else { throw GoogleDriveError.notDownloadable }
            update(record.id) { $0.file = current; $0.expected = current.exportFormat == nil ? current.size : nil }
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let free, let size = current.size, current.exportFormat == nil, size > free - 10 * 1024 * 1024 { throw GoogleDriveError.noSpace }
            let location = try await client.download(current) { [weak self] received, expected in
                Task { @MainActor in self?.update(record.id) {
                    guard $0.state == .downloading else { return }
                    $0.received = received; if expected >= 0 { $0.expected = expected }
                } }
            }
            temporary = location
            try Task.checkCancellation()
            guard let item = records.first(where: { $0.id == record.id }), item.state == .downloading,
                  clients[record.owner] != nil else { throw CancellationError() }
            let target = fileURL(item)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            temporary = nil
            let count = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            update(record.id) { $0.state = .completed; $0.received = count; $0.expected = count; $0.message = nil }
        } catch {
            update(record.id) {
                guard $0.state == .downloading else { return }
                $0.state = Task.isCancelled ? .cancelled : .failed
                $0.message = Task.isCancelled ? nil : googleDriveErrorMessage(error)
            }
        }
    }
    private func update(_ id: UUID, _ change: (inout GoogleDriveDownload) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index]); persist()
    }
    private func persist() {
        guard loaded else { return }
        do { try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtection]) }
        catch { self.error = "无法保存 Google Drive 下载记录，请检查本机剩余空间。" }
    }
}
