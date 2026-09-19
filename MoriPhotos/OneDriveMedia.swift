import Foundation
import SwiftUI
import QuickLook
import CryptoKit

enum OneDriveMediaError: LocalizedError {
    case invalidURL, response(Int), incomplete, tooLarge, noSpace, folder, unsupported, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "OneDrive 返回了不安全的文件地址，请重新连接后重试。"
        case .response(let status): return status == 401 || status == 403 ? "文件链接已失效或没有读取权限，请重新打开文件。" : "文件服务暂时不可用（\(status)），请重试。"
        case .incomplete: return "文件内容不完整或已发生变化，请刷新目录后重新下载。"
        case .tooLarge: return "快速预览支持 30 MB 以内的文件，请先下载较大的文件。"
        case .noSpace: return "本机剩余空间不足，无法继续下载。"
        case .folder: return "请选择文件进行下载。"
        case .unsupported: return "这种文件暂不支持快速预览，可以下载后用其他应用打开。"
        case .unavailable: return "无法读取文件，请检查网络及 OneDrive 连接后重试。"
        }
    }
}

enum OneDriveMediaIdentity {
    static func digest(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func accountKey(_ accountID: String) -> String { digest(["onedrive-account", accountID]) }
    static func key(item: OneDriveItem, accountID: String) -> String {
        digest(["onedrive-file", accountID, item.driveID ?? "", item.id, item.eTag ?? "",
                item.size.map(String.init) ?? "", item.modified.map { String($0.timeIntervalSince1970) } ?? ""])
    }
    static func safeName(_ name: String) -> String {
        let leaf = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = leaf.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "download" }
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 24 ? "" : "." + ext
        var stem = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > 200 { stem.removeLast() }
        return stem + suffix
    }
    static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

/// Only URLs obtained from Graph may enter this layer. A preauthenticated content
/// URL does not need the Graph bearer token; every hop starts with clean headers.
enum OneDriveContentPolicy {
    static func request(for url: URL) throws -> URLRequest {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw OneDriveMediaError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

/// Streams each bounded URLSession data chunk straight to an owned temporary file.
/// No file-sized Data, shared credential storage, or shared cookie jar is used.
final class OneDriveContentTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let expectedSize: Int64?
    private let byteLimit: Int64?
    private let limitError: OneDriveMediaError
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private var started = false
    private var failure: Error?
    private var location: URL?
    private var handle: FileHandle?
    private var responseSize: Int64?
    private var received: Int64 = 0
    private var redirects = 0
    private var lastProgress = Date.distantPast

    init(configuration: URLSessionConfiguration = .ephemeral, expectedSize: Int64?, byteLimit: Int64? = nil, limitError: OneDriveMediaError = .tooLarge,
         progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        var configuration = configuration
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if OneDriveFixture.enabled { configuration = OneDriveFixture.configuration() }
        #endif
        self.configuration = configuration; self.expectedSize = expectedSize; self.byteLimit = byteLimit; self.limitError = limitError; self.progress = progress
    }
    func run(url: URL) async throws -> URL {
        let request = try OneDriveContentPolicy.request(for: url)
        if let expectedSize, let byteLimit, expectedSize > byteLimit { throw limitError }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled, !started else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                started = true
                self.continuation = continuation
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.httpAdditionalHeaders = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            redirects += 1
            guard redirects <= 5, let url = request.url else { throw OneDriveMediaError.invalidURL }
            completionHandler(try OneDriveContentPolicy.request(for: url))
        } catch { failure = error; completionHandler(nil); task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Preserve normal platform TLS validation. Never answer server/proxy auth
        // challenges using the user's credentials or a persisted credential store.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse, let url = response.url else { throw OneDriveMediaError.unavailable }
            _ = try OneDriveContentPolicy.request(for: url)
            guard response.statusCode == 200 else { throw OneDriveMediaError.response(response.statusCode) }
            responseSize = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            if let byteLimit, let responseSize, responseSize > byteLimit { throw limitError }
            if let expectedSize, expectedSize >= 0, let responseSize, responseSize != expectedSize { throw OneDriveMediaError.incomplete }
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("MoriOneDrive-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw OneDriveMediaError.noSpace }
            location = temporaryURL; handle = try FileHandle(forWritingTo: temporaryURL)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            let count = Int64(data.count)
            if let byteLimit, received > byteLimit - count { throw limitError }
            guard let handle else { throw OneDriveMediaError.unavailable }
            try handle.write(contentsOf: data); received += count
            if Date().timeIntervalSince(lastProgress) >= 0.15 || received == responseSize {
                lastProgress = Date(); progress(received, expectedSize ?? responseSize)
            }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.close() } catch { if failure == nil { failure = error } }; handle = nil
        lock.lock()
        let cancelled = cancelled
        let continuation = continuation; self.continuation = nil; self.task = nil; self.session = nil
        lock.unlock()
        var outcome: Result<URL, Error>
        if cancelled { outcome = .failure(CancellationError()) }
        else if let error = failure ?? error { outcome = .failure(error) }
        else if let expectedSize, expectedSize >= 0, received != expectedSize { outcome = .failure(OneDriveMediaError.incomplete) }
        else if let responseSize, received != responseSize { outcome = .failure(OneDriveMediaError.incomplete) }
        else if let location { outcome = .success(location) }
        else { outcome = .failure(OneDriveMediaError.unavailable) }
        if case .failure = outcome, let location { try? FileManager.default.removeItem(at: location) }
        if case .success = outcome { progress(received, expectedSize ?? responseSize ?? received) }
        location = nil
        continuation?.resume(with: outcome); session.finishTasksAndInvalidate()
    }
}

enum OneDriveDownloadState: String, Codable, Sendable {
    case queued, downloading, completed, failed, cancelled
    var active: Bool { self == .queued || self == .downloading }
    var title: String {
        switch self { case .queued: "排队中"; case .downloading: "下载中"; case .completed: "已下载"; case .failed: "下载失败"; case .cancelled: "已取消" }
    }
}

struct OneDriveDownloadRecord: Codable, Identifiable, Sendable {
    let id: String
    let accountKey: String
    let itemID: String
    let driveID: String?
    let eTag: String?
    let name: String
    let created: Date
    var state: OneDriveDownloadState
    var received: Int64
    var expected: Int64?
    var message: String?
    var localName: String { OneDriveMediaIdentity.safeName(name) }
    var active: Bool { state.active }
    var fraction: Double? { guard let expected, expected > 0 else { return nil }; return min(1, Double(received) / Double(expected)) }
}

struct OneDriveTransferState {
    let state: OneDriveDownloadState
    let received: Int64
    let expected: Int64?
    let message: String?
}

extension Notification.Name {
    static let oneDriveMediaAccountDisconnected = Notification.Name("MoriOneDriveAccountDisconnected")
}

@MainActor
final class OneDriveMediaStore: ObservableObject {
    static let shared: OneDriveMediaStore = {
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if OneDriveFixture.enabled {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoriOneDriveUITestDownloads", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            return OneDriveMediaStore(directory: directory)
        }
        #endif
        return OneDriveMediaStore()
    }()
    @Published private(set) var records: [OneDriveDownloadRecord] = []
    @Published private(set) var transfers: [String: OneDriveTransferState] = [:]
    @Published var error: String?
    private let directory: URL
    private var loaded = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var clients: [String: any OneDriveServing] = [:]
    var transferConfiguration: (() -> URLSessionConfiguration)?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OneDriveDownloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var folder = self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            let manifest = self.directory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                records = try JSONDecoder().decode([OneDriveDownloadRecord].self, from: Data(contentsOf: manifest))
                    .filter { OneDriveMediaIdentity.validDigest($0.id) && OneDriveMediaIdentity.validDigest($0.accountKey) }
                for index in records.indices {
                    if records[index].active { records[index].state = .cancelled; records[index].message = "上次下载已中断，可重新下载。" }
                    if records[index].state == .completed, !FileManager.default.fileExists(atPath: fileURL(records[index]).path) {
                        records[index].state = .failed; records[index].message = "本地文件已不存在，请重新下载。"
                    }
                }
            }
            loaded = true; persist()
        } catch { self.error = "无法读取 OneDrive 下载记录，请检查本机存储空间。" }
    }
    func records(for accountID: String) -> [OneDriveDownloadRecord] {
        let account = OneDriveMediaIdentity.accountKey(accountID)
        return records.filter { $0.accountKey == account }
    }
    @discardableResult
    func enqueue(item: OneDriveItem, client: any OneDriveServing, accountID: String) -> String {
        let id = OneDriveMediaIdentity.key(item: item, accountID: accountID)
        guard loaded, !item.isFolder else { if item.isFolder { error = OneDriveMediaError.folder.localizedDescription }; return id }
        guard jobs[id] == nil, records.first(where: { $0.id == id })?.active != true else { return id }
        if let record = records.first(where: { $0.id == id }), localURL(for: record) != nil { return id }
        records.removeAll { $0.id == id }
        let account = OneDriveMediaIdentity.accountKey(accountID)
        records.insert(OneDriveDownloadRecord(id: id, accountKey: account, itemID: item.id, driveID: item.driveID,
            eTag: item.eTag, name: item.name, created: Date(), state: .queued, received: 0, expected: item.size, message: nil), at: 0)
        clients[account] = client; persist(); pump(); return id
    }
    func cancel(id: String) {
        update(id) { if $0.active { $0.state = .cancelled; $0.message = nil } }
        jobs[id]?.cancel(); persist(); pump()
    }
    func cancel(accountID: String) {
        let account = OneDriveMediaIdentity.accountKey(accountID)
        clients[account] = nil
        for id in records.filter({ $0.accountKey == account && $0.active }).map(\.id) {
            update(id) { $0.state = .cancelled; $0.message = "连接已断开，下载已取消。" }; jobs[id]?.cancel()
        }
        persist()
        NotificationCenter.default.post(name: .oneDriveMediaAccountDisconnected, object: account)
    }
    func remove(record: OneDriveDownloadRecord) {
        guard OneDriveMediaIdentity.validDigest(record.id), OneDriveMediaIdentity.validDigest(record.accountKey),
              let current = records.first(where: { $0.id == record.id && $0.accountKey == record.accountKey }),
              jobs[record.id] == nil, !current.active else { return }
        do {
            let folder = fileURL(record).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            records.removeAll { $0.id == record.id }; transfers[record.id] = nil; persist()
        } catch { self.error = "无法移除本地文件，请稍后再试。" }
    }
    func localURL(for record: OneDriveDownloadRecord) -> URL? {
        guard OneDriveMediaIdentity.validDigest(record.id), OneDriveMediaIdentity.validDigest(record.accountKey), record.state == .completed else { return nil }
        let url = fileURL(record)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func localURL(for item: OneDriveItem, accountID: String) -> URL? {
        guard let record = records.first(where: { $0.id == OneDriveMediaIdentity.key(item: item, accountID: accountID) }) else { return nil }
        return localURL(for: record)
    }
    private func fileURL(_ record: OneDriveDownloadRecord) -> URL {
        directory.appendingPathComponent(record.accountKey, isDirectory: true).appendingPathComponent(record.id, isDirectory: true).appendingPathComponent(record.localName)
    }
    private func pump() {
        for record in records.reversed() where jobs.count < 2 && record.state == .queued {
            guard let client = clients[record.accountKey], jobs[record.id] == nil else { continue }
            update(record.id) { $0.state = .downloading }
            jobs[record.id] = Task { [weak self] in
                guard let self else { return }
                await self.run(record: record, client: client)
                self.jobs[record.id] = nil; self.persist(); self.pump()
            }
        }
    }
    private func run(record: OneDriveDownloadRecord, client: any OneDriveServing) async {
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let current = try await client.item(id: record.itemID)
            try Task.checkCancellation()
            guard !current.isFolder, current.id == record.itemID,
                  record.eTag == nil || current.eTag == record.eTag else { throw OneDriveMediaError.incomplete }
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let available = free.map { max(0, $0 - 20 * 1024 * 1024) }
            if let available, let size = current.size, size > available { throw OneDriveMediaError.noSpace }
            let url = try await client.downloadURL(for: record.itemID)
            try Task.checkCancellation()
            let transfer = OneDriveContentTransfer(configuration: transferConfiguration?() ?? .ephemeral,
                expectedSize: current.size, byteLimit: available, limitError: .noSpace) { [weak self] received, expected in
                Task { @MainActor in self?.update(record.id) { if $0.state == .downloading { $0.received = received; $0.expected = expected } } }
            }
            let location = try await transfer.run(url: url); temporary = location
            try Task.checkCancellation()
            guard records.first(where: { $0.id == record.id })?.state == .downloading else { throw CancellationError() }
            let destination = fileURL(record)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            update(record.id) { $0.state = .completed; $0.received = size; $0.expected = size; $0.message = nil }
        } catch {
            update(record.id) {
                if Task.isCancelled || error is CancellationError { $0.state = .cancelled }
                else { $0.state = .failed; $0.message = oneDriveMediaMessage(error) }
            }
        }
    }
    private func update(_ id: String, _ change: (inout OneDriveDownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        let record = records[index]
        transfers[id] = OneDriveTransferState(state: record.state, received: record.received, expected: record.expected, message: record.message)
    }
    private func persist() {
        guard loaded else { return }
        do { try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtection]) }
        catch { self.error = "OneDrive 下载记录保存失败，请检查本机存储空间。" }
    }
}

private func oneDriveMediaMessage(_ error: Error) -> String {
    if let error = error as? OneDriveMediaError { return error.localizedDescription }
    if let error = error as? OneDriveError { return error.localizedDescription }
    // URLSession errors may embed a signed content URL. Keep it out of UI/logs.
    if (error as NSError).domain == NSURLErrorDomain { return "文件读取失败，请检查网络后重试。" }
    return "无法读取文件，请重新连接 OneDrive 后重试。"
}

@MainActor
final class OneDrivePreviewModel: ObservableObject {
    static let limit: Int64 = 30_000_000
    @Published var url: URL?
    @Published var error: String?
    @Published var received: Int64 = 0
    private var generation = UUID()
    private var transfer: OneDriveContentTransfer?
    private var directory: URL?
    func load(item: OneDriveItem, client: any OneDriveServing, accountID: String, configuration: URLSessionConfiguration = .ephemeral) async {
        stop(); error = nil; received = 0
        let ticket = generation
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            if let local = OneDriveMediaStore.shared.localURL(for: item, accountID: accountID) { try display(local); return }
            let current = try await client.item(id: item.id)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            guard !current.isFolder else { throw OneDriveMediaError.folder }
            let url = try await client.downloadURL(for: item.id)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let transfer = OneDriveContentTransfer(configuration: configuration, expectedSize: current.size, byteLimit: Self.limit) { [weak self] bytes, _ in
                Task { @MainActor in guard let self, self.generation == ticket else { return }; self.received = bytes }
            }
            self.transfer = transfer
            let location = try await transfer.run(url: url); temporary = location
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoriOneDrivePreview-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            self.directory = directory
            let target = directory.appendingPathComponent(OneDriveMediaIdentity.safeName(current.name))
            try FileManager.default.moveItem(at: location, to: target)
            try display(target)
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = oneDriveMediaMessage(error)
            if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        }
    }
    private func display(_ url: URL) throws {
        #if targetEnvironment(macCatalyst)
        guard QLPreviewController.canPreviewItem(url as NSURL) else { throw OneDriveMediaError.unsupported }
        #else
        guard QLPreviewController.canPreview(url as NSURL) else { throw OneDriveMediaError.unsupported }
        #endif
        self.url = url
    }
    func stop() {
        generation = UUID(); transfer?.cancel(); transfer = nil; url = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
}

struct OneDrivePreviewView: View {
    let item: OneDriveItem
    let client: any OneDriveServing
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OneDrivePreviewModel()
    @ObservedObject private var downloads = OneDriveMediaStore.shared
    @State private var attempt = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let url = model.url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享文件") }
                Button("完成") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("oneDrivePreviewDone")
            }.padding(16)
            Divider()
            Group {
                if let url = model.url { OneDriveNativeQuickLook(url: url).accessibilityIdentifier("oneDriveQuickLook") }
                else if let error = model.error {
                    ContentUnavailableView { Label("无法预览", systemImage: "doc") } description: { Text(error) } actions: {
                        Button("重试") { attempt = UUID() }
                        Button("下载文件") { downloads.enqueue(item: item, client: client, accountID: accountID) }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView("正在准备预览…")
                        Text(ByteCountFormatter.string(fromByteCount: model.received, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.desktopSheet(width: 800, height: 620)
            .task(id: attempt) { await model.load(item: item, client: client, accountID: accountID) }
            .onDisappear { model.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .oneDriveMediaAccountDisconnected)) { notification in
                if notification.object as? String == OneDriveMediaIdentity.accountKey(accountID) { model.stop(); dismiss() }
            }
    }
}

struct OneDriveNativeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct OneDrivePlaybackView: View {
    let item: OneDriveItem
    let client: any OneDriveServing
    let accountID: String
    var localURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = VideoPlaybackModel()
    @State private var attempt = UUID()
    @State private var resolving = false
    @State private var linkError: String?
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    NativeVideoPlayer(player: model.player)
                    if resolving || model.preparing || model.buffering {
                        ProgressView(resolving || model.preparing ? "正在准备视频…" : "正在缓冲…")
                            .padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    if let error = linkError ?? model.error {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                        Button("重试播放") { attempt = UUID() }.buttonStyle(.bordered)
                    } else {
                        HStack(spacing: 38) {
                            Button { model.jump(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("后退15秒")
                            Button { model.toggle() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(model.playing ? "暂停" : "播放")
                            Button { model.jump(15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("前进15秒")
                        }.font(.title2).disabled(resolving || model.preparing || model.duration <= 0)
                        Text("\(time(model.elapsed)) / \(time(model.duration))").font(.caption.monospacedDigit())
                    }
                    if model.duration > 0 {
                        HStack {
                            if let position = model.resumedFrom { Text("已从 \(time(position)) 继续").foregroundStyle(.secondary) }
                            Button("从头播放") { model.restart() }.disabled(model.preparing)
                        }.font(.caption)
                    }
                    if let error = model.progressError { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text(item.name).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }.padding(20)
            }.background(.black).preferredColorScheme(.dark)
                .navigationTitle(localURL == nil ? "OneDrive 在线播放" : "本地播放").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { generation = UUID(); model.stop(); dismiss() } } }
        }.tint(.mint).desktopSheet(width: 960, height: 680)
            .task(id: attempt) { await open() }
            .onDisappear { generation = UUID(); model.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause() } }
            .onReceive(NotificationCenter.default.publisher(for: .oneDriveMediaAccountDisconnected)) { notification in
                if notification.object as? String == OneDriveMediaIdentity.accountKey(accountID) { generation = UUID(); model.stop(); dismiss() }
            }
    }
    private func open() async {
        model.stop(); linkError = nil; resolving = true
        generation = UUID(); let ticket = generation
        defer { if ticket == generation { resolving = false } }
        do {
            let current: OneDriveItem
            let url: URL
            if let localURL { current = item; url = localURL }
            else {
                current = try await client.item(id: item.id)
                url = try await client.downloadURL(for: item.id)
                _ = try OneDriveContentPolicy.request(for: url)
            }
            try Task.checkCancellation()
            guard ticket == generation else { return }
            resolving = false
            await model.openExternal(url: url, progressKey: OneDriveMediaIdentity.key(item: current, accountID: accountID), canPlayNatively: current.canPlayNatively)
        } catch { if !Task.isCancelled, ticket == generation { linkError = oneDriveMediaMessage(error) } }
    }
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
