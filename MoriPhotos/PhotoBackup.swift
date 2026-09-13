import Foundation
import Photos
import CryptoKit

enum PhotoBackupError: LocalizedError {
    case fullAccess, connection, targetChanged, ledger, original, conflict, verification, cancelled
    var errorDescription: String? {
        switch self {
        case .fullAccess: return "请允许访问全部照片，才能自动发现新拍摄的照片。"
        case .connection: return "请先连接 File Station，并保存登录信息。"
        case .targetChanged: return "当前 NAS 账号与备份账号不同，已暂停上传。请切回原账号，或关闭备份后重新选择位置。"
        case .ledger: return "备份记录无法读取或保存，已停止上传，避免丢失记录。请稍后重试。"
        case .original: return "无法完整读取这张照片的原始文件，稍后会重试。"
        case .conflict: return "NAS 上有同名但内容不同的文件。已停止，未覆盖原文件；请检查备份目录。"
        case .verification: return "NAS 文件校验未完成，暂未记为已备份。稍后会继续核对。"
        case .cancelled: return "备份已暂停。"
        }
    }
}

struct BackupCandidate: Identifiable, Equatable {
    let id: String
    let created: Date
    let isScreenshot: Bool
}

struct BackupConfiguration: Codable, Equatable {
    var enabled = false
    var owner = ""
    var folder = "/home/Photos/MoriBackup"
    var startedAt: Date?
    var wifiOnly = true
}

// A durable receipt is written only after every original resource has been verified remotely.
struct BackupLedger: Codable {
    var configuration = BackupConfiguration()
    var completed: Set<String> = []
    var lastCompletedAt: Date?

    mutating func selectFolder(owner: String, folder: String, now: Date) throws {
        try NASFile.validatePath(folder)
        guard !owner.isEmpty else { throw PhotoBackupError.connection }
        if configuration.owner != owner || configuration.folder != folder {
            completed = []; lastCompletedAt = nil
            configuration.startedAt = configuration.enabled ? now : nil
        }
        configuration.owner = owner; configuration.folder = folder
    }

    func pending(_ candidates: [BackupCandidate]) -> [BackupCandidate] {
        guard configuration.enabled, let start = configuration.startedAt else { return [] }
        var seen = completed
        return candidates.filter { $0.created >= start && !$0.isScreenshot && seen.insert($0.id).inserted }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    mutating func enable(owner: String, folder: String, wifiOnly: Bool, now: Date) throws {
        try NASFile.validatePath(folder)
        guard !owner.isEmpty else { throw PhotoBackupError.connection }
        if configuration.owner != owner || configuration.folder != folder || configuration.startedAt == nil {
            completed = []; lastCompletedAt = nil; configuration.startedAt = now
        }
        configuration.owner = owner; configuration.folder = folder
        configuration.wifiOnly = wifiOnly; configuration.enabled = true
    }
}

struct BackupLedgerFile {
    let url: URL
    func load() throws -> BackupLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return BackupLedger() }
        return try JSONDecoder().decode(BackupLedger.self, from: Data(contentsOf: url))
    }
    func save(_ ledger: BackupLedger) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try JSONEncoder().encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct BackupOriginal {
    let url: URL
    let filename: String
    let bytes: Int64
    let md5: String
    let created: Date

    static func inspect(url: URL, assetID: String, resourceType: Int, originalName: String, created: Date) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.MD5(), count: Int64 = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count); hash.update(data: data)
        }
        guard count > 0 else { throw PhotoBackupError.original }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = SHA256.hash(data: Data((assetID + ":" + String(resourceType)).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let ext = (originalName as NSString).pathExtension.lowercased()
        guard ext.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil else { throw PhotoBackupError.original }
        // One stable name per original. Camera names such as IMG_0001 never collide across assets/devices.
        return Self(url: url, filename: "Mori-\(identity)-\(digest).\(ext)", bytes: count, md5: digest, created: created)
    }
}

enum BackupPhotoLibrary {
    static func candidates(since date: Date) -> [BackupCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", date as NSDate)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var items: [BackupCandidate] = []
        fetched.enumerateObjects { asset, _, _ in
            if let created = asset.creationDate {
                items.append(BackupCandidate(id: asset.localIdentifier, created: created, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
            }
        }
        return items
    }
    static func originals(for candidate: BackupCandidate, directory: URL, allowCloud: Bool) async throws -> [BackupOriginal] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject else { throw PhotoBackupError.original }
        let resources = PHAssetResource.assetResources(for: asset).filter { [.photo, .alternatePhoto, .pairedVideo].contains($0.type) }
        guard resources.contains(where: { $0.type == .photo }),
              !asset.mediaSubtypes.contains(.photoLive) || resources.contains(where: { $0.type == .pairedVideo }) else { throw PhotoBackupError.original }
        var result: [BackupOriginal] = []
        for resource in resources {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(UUID().uuidString)
            let export = try BackupResourceExport(url: url)
            try await export.write(resource, allowCloud: allowCloud)
            try Task.checkCancellation()
            let name = resource.originalFilename, type = resource.type.rawValue
            let original = try await Task.detached(priority: .utility) {
                try BackupOriginal.inspect(url: url, assetID: candidate.id, resourceType: type, originalName: name, created: candidate.created)
            }.value
            result.append(original)
        }
        return result
    }
    static func monthFolder(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", parts.year!, parts.month!)
    }
}

// Stream PhotoKit originals to disk; cancellation also stops any iCloud resource download.
private final class BackupResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private let manager = PHAssetResourceManager.default()
    private let handle: FileHandle
    private var request: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var writeError: Error?
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw PhotoBackupError.original }
        handle = try FileHandle(forWritingTo: url)
    }
    func write(_ resource: PHAssetResource, allowCloud: Bool) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowCloud
                let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { data in
                    self.lock.lock(); defer { self.lock.unlock() }
                    guard !self.cancelled, self.writeError == nil else { return }
                    do { try self.handle.write(contentsOf: data) } catch { self.writeError = error }
                }, completionHandler: { error in
                    self.lock.lock()
                    var result = self.writeError ?? error
                    if self.cancelled { result = CancellationError() }
                    do { try self.handle.close() } catch { if result == nil { result = error } }
                    self.lock.unlock()
                    if let result { continuation.resume(throwing: result) } else { continuation.resume() }
                })
                lock.lock(); request = id; let stop = cancelled; lock.unlock()
                if stop { manager.cancelDataRequest(id) }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let id = request; lock.unlock()
        if let id { manager.cancelDataRequest(id) }
    }
    deinit { try? handle.close() }
}

enum BackupMultipart {
    static func write(fields: [(String, String)], original: BackupOriginal, to url: URL, boundary: String) throws -> Int64 {
        guard original.filename.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw PhotoBackupError.original }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw PhotoBackupError.original }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        func append(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
        for (key, value) in fields {
            guard key.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { throw PhotoBackupError.original }
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(original.filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: original.url); defer { try? input.close() }
        while let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: bytes) }
        try append("\r\n--\(boundary)--\r\n")
        return Int64(try output.offset())
    }
}

extension SynologyClient {
    func verifyBackupDestination(_ folder: String) async throws {
        try NASFile.validatePath(folder)
        _ = try makeRequest(api: "SYNO.FileStation.Upload", method: "upload", parameters: [:], version: 2)
        _ = try makeRequest(api: "SYNO.FileStation.MD5", method: "start", parameters: [:], version: 2)
        // Directory creation happens only when the first new photo actually uploads.
        // Validate the existing ancestor and write permission before enabling the feature.
        var parent = folder
        while true {
            do {
                _ = try await files(path: parent, offset: 0, limit: 1)
                let _: EmptyResponse = try await call(api: "SYNO.FileStation.CheckPermission", method: "write", parameters: ["path": parent, "filename": "MoriBackup-write-check", "create_only": true], version: 3)
                return
            } catch FileStationError.api(408) {
                let next = (parent as NSString).deletingLastPathComponent
                guard next != "/", next != parent else { throw FileStationError.invalidPath }; parent = next
            }
        }
    }
    func verifiedBackupExists(path: String, original: BackupOriginal) async throws -> Bool {
        let remote: NASFile
        do { remote = try await fileInfo(path: path) }
        catch FileStationError.api(408) { return false }
        guard remote.size == original.bytes else { throw PhotoBackupError.conflict }
        struct MD5Start: Decodable { let taskid: String }
        struct MD5Status: Decodable { let finished: Bool; let md5: String? }
        let job: MD5Start = try await call(api: "SYNO.FileStation.MD5", method: "start", parameters: ["file_path": path], version: 2)
        do {
            for _ in 0..<30 {
                try Task.checkCancellation()
                let status: MD5Status = try await call(api: "SYNO.FileStation.MD5", method: "status", parameters: ["taskid": job.taskid], version: 2)
                if status.finished {
                    guard status.md5?.lowercased() == original.md5 else { throw PhotoBackupError.conflict }
                    return true
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw PhotoBackupError.verification
        } catch {
            let _: EmptyResponse? = try? await call(api: "SYNO.FileStation.MD5", method: "stop", parameters: ["taskid": job.taskid], version: 2)
            throw error
        }
    }
}
