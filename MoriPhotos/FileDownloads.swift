import Foundation

struct NASDownload: Codable, Identifiable {
    enum State: String, Codable { case queued, downloading, completed, failed, cancelled
        var title: String { switch self { case .queued: return "排队中"; case .downloading: return "下载中"; case .completed: return "已下载"; case .failed: return "下载失败"; case .cancelled: return "已取消" } }
    }
    let id: UUID
    let owner: String
    var file: NASFile
    let created: Date
    var state: State = .queued
    var received: Int64 = 0
    var expected: Int64?
    var message: String?
    var active: Bool { state == .queued || state == .downloading }
    var localName: String {
        let name = (file.name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        guard !name.isEmpty, name != ".", name != ".." else { return "download" }
        let ext = (name as NSString).pathExtension
        let suffix = ext.utf8.count <= 24 && !ext.isEmpty ? "." + ext : ""
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > 220 { stem.removeLast() }
        return stem + suffix
    }
}

// Each operation owns its session. Cancellation and delegate completion may arrive
// on different queues; the lock also covers cancellation before a task is created.
final class FileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var result: Result<(URL, HTTPURLResponse), Error>?
    private var cancelled = false
    private var limitExceeded = false
    private let byteLimit: Int64?
    private let progress: @Sendable (Int64, Int64) -> Void
    private let configuration: URLSessionConfiguration
    private var lastProgress = Date.distantPast
    init(configuration: URLSessionConfiguration = .ephemeral, byteLimit: Int64? = nil, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.configuration = configuration; self.progress = progress; self.byteLimit = byteLimit
    }
    func run(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                configuration.httpCookieStorage = nil; configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                task = session.downloadTask(with: request)
                task?.resume()
                lock.unlock()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let byteLimit, totalBytesWritten > byteLimit || totalBytesExpectedToWrite > byteLimit {
            lock.lock(); limitExceeded = true; lock.unlock(); downloadTask.cancel(); return
        }
        let now = Date()
        if now.timeIntervalSince(lastProgress) > 0.2 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = now; progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let byteLimit, ((try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0) > byteLimit {
                lock.lock(); limitExceeded = true; lock.unlock(); throw FilePreviewError.tooLarge
            }
            guard let response = downloadTask.response as? HTTPURLResponse else { throw NASError.invalidResponse }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("mori-download-" + UUID().uuidString)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: location.path)
            try FileManager.default.moveItem(at: location, to: target)
            lock.lock(); result = .success((target, response)); lock.unlock()
        } catch { lock.lock(); result = .failure(error); lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let saved = result
        let outcome: Result<(URL, HTTPURLResponse), Error> = cancelled ? .failure(CancellationError()) : limitExceeded ? .failure(FilePreviewError.tooLarge) : error.map { .failure($0) } ?? saved ?? .failure(NASError.invalidResponse)
        let completion = continuation; continuation = nil; self.task = nil; self.session = nil
        lock.unlock()
        if case .failure = outcome, case .success(let file) = saved { try? FileManager.default.removeItem(at: file.0) }
        completion?.resume(with: outcome)
        session.finishTasksAndInvalidate()
    }
    static func validate(file: URL, response: HTTPURLResponse, expected: Int64?) throws {
        if (300..<400).contains(response.statusCode) { throw NASError.redirect }
        guard (200..<300).contains(response.statusCode) else { throw NASError.http(response.statusCode) }
        let attached = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        // mode=download specifies attachment/octet-stream even for a JSON file.
        // Never classify a legitimate attached JSON file as an API error.
        if !attached && response.mimeType?.lowercased() != "application/octet-stream" {
            if size < 1_048_576, let data = try? Data(contentsOf: file),
               let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: data), !envelope.success {
                throw FileStationError.api(envelope.error?.code ?? -1)
            }
            throw FileStationError.notDownload
        }
        if let expected, expected >= 0, Int64(size) != expected { throw FileStationError.incomplete }
    }
}

@MainActor
final class NASDownloadManager: ObservableObject {
    @Published private(set) var records: [NASDownload] = []
    @Published var error: String?
    private let directory: URL
    private var loaded = false
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var clients: [String: SynologyClient] = [:]
    // Injection is used by isolated simulator tests, never stored in a task record.
    var transferConfiguration: (() -> URLSessionConfiguration)?
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NASDownloads", isDirectory: true)
        reloadIfNeeded()
    }
    func reloadIfNeeded() {
        guard !loaded, jobs.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var folder = self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            let manifest = self.directory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                records = try JSONDecoder().decode([NASDownload].self, from: Data(contentsOf: manifest))
                for index in records.indices {
                    if records[index].active { records[index].state = .failed; records[index].message = "上次下载已中断，连接文件服务后可从头重试。" }
                    if records[index].state == .completed && !FileManager.default.fileExists(atPath: fileURL(records[index]).path) {
                        records[index].state = .failed; records[index].message = "本地文件已不存在，请重新下载。"
                    }
                }
            }
            loaded = true; error = nil; persist()
        } catch { self.error = "无法读取下载记录：\(friendlyError(error))" }
    }
    func fileURL(_ record: NASDownload) -> URL {
        directory.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.localName)
    }
    func enqueue(_ file: NASFile, owner: String, client: SynologyClient) {
        reloadIfNeeded()
        guard loaded, !file.isdir, !records.contains(where: { $0.owner == owner && $0.file.path == file.path && $0.active }) else { return }
        records.insert(NASDownload(id: UUID(), owner: owner, file: file, created: Date(), expected: file.size), at: 0)
        clients[owner] = client; persist(); pump()
    }
    func retry(_ record: NASDownload, client: SynologyClient, owner: String) {
        guard record.owner == owner, let index = records.firstIndex(where: { $0.id == record.id }), !records[index].active, records[index].state != .completed, jobs[record.id] == nil else { return }
        records[index].state = .queued; records[index].received = 0; records[index].message = nil
        clients[owner] = client; persist(); pump()
    }
    func cancel(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].active else { return }
        records[index].state = .cancelled; records[index].message = nil
        jobs[id]?.cancel(); persist(); pump()
    }
    func cancelActive(owner: String) {
        // Mark every item before pumping, so disconnect never starts the next item.
        clients[owner] = nil
        for index in records.indices where records[index].owner == owner && records[index].active {
            records[index].state = .cancelled; records[index].message = "连接已断开，可重新连接后重试。"
            jobs[records[index].id]?.cancel()
        }
        persist()
    }
    func remove(_ record: NASDownload) {
        guard !record.active, jobs[record.id] == nil else { return }
        do {
            let folder = directory.appendingPathComponent(record.id.uuidString)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            records.removeAll { $0.id == record.id }; persist()
        } catch { self.error = friendlyError(error) }
    }
    private func pump() {
        for record in records.reversed() where jobs.count < 2 && record.state == .queued {
            guard let client = clients[record.owner], jobs[record.id] == nil else { continue }
            let id = record.id
            update(id) { $0.state = .downloading }
            jobs[id] = Task { [weak self] in
                guard let self else { return }
                await self.run(record, client: client)
                self.jobs[id] = nil; self.persist(); self.pump()
            }
        }
    }
    private func run(_ record: NASDownload, client: SynologyClient) async {
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let current = try await client.fileInfo(path: record.file.path)
            try Task.checkCancellation()
            update(record.id) { $0.file = current; $0.expected = current.size }
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let free, let size = current.size, size > free - 10 * 1024 * 1024 { throw FileStationError.noSpace }
            let request = try await client.fileDownloadRequest(path: current.path)
            let operation = FileTransfer(configuration: transferConfiguration?() ?? .ephemeral) { [weak self] received, expected in
                Task { @MainActor in
                    self?.update(record.id) { item in
                        guard item.state == .downloading else { return }
                        item.received = received
                        if expected >= 0 { item.expected = expected }
                    }
                }
            }
            let (location, response) = try await operation.run(request)
            temporary = location
            try Task.checkCancellation()
            try FileTransfer.validate(file: location, response: response, expected: current.size)
            guard let item = records.first(where: { $0.id == record.id }), item.state == .downloading else { throw CancellationError() }
            let target = fileURL(item)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            update(record.id) { $0.state = .completed; $0.received = Int64(size); $0.expected = Int64(size); $0.message = nil }
        } catch {
            update(record.id) {
                if Task.isCancelled || error is CancellationError { $0.state = .cancelled }
                else { $0.state = .failed; $0.message = friendlyError(error) }
            }
        }
    }
    private func update(_ id: UUID, _ change: (inout NASDownload) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
    private func persist() {
        // A locked device or unreadable manifest must never be replaced by an empty list.
        guard loaded else { return }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: directory.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtection])
        } catch { self.error = "下载记录保存失败：\(friendlyError(error))" }
    }
}
