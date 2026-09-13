import Foundation
import CryptoKit

enum NASService: String {
    case photos = "SynologyPhotos", files = "FileStation", monitor = "DSM"
    var requiredAPI: String {
        switch self {
        case .photos: return "SYNO.Foto.Browse.Item"
        case .files: return "SYNO.FileStation.List"
        case .monitor: return "SYNO.Core.System"
        }
    }
    var title: String {
        switch self {
        case .photos: return "Synology Photos"
        case .files: return "File Station"
        case .monitor: return "NAS 状态"
        }
    }
    func baseURL(_ address: String) throws -> URL {
        let url = try SynologyClient.normalizedAddress(address)
        // The standard Photos portal lives below /photo; File Station uses DSM's root.
        if self != .photos && url.path == "/photo" { return url.deletingLastPathComponent() }
        return url
    }
    static func accountID(_ credentials: NASCredentials) -> String {
        let address = (try? NASService.files.baseURL(credentials.address).absoluteString) ?? credentials.address
        return SHA256.hash(data: Data((address + "\n" + credentials.username).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum FileStationError: LocalizedError {
    case unavailable, api(Int), invalidPath, incomplete, noSpace, notDownload
    var errorDescription: String? {
        switch self {
        case .unavailable: return "NAS 未提供兼容的 File Station 接口。请使用 DSM 地址，并检查 File Station 套件和账号权限。"
        case .invalidPath: return "文件路径无效，请刷新目录后重试。"
        case .incomplete: return "文件大小与服务器信息不一致，可能下载不完整或文件已被修改。请刷新后重新下载。"
        case .noSpace: return "本机剩余空间不足，请释放空间后重新下载。"
        case .notDownload: return "服务器没有返回文件内容。请重新连接文件服务，并检查 File Station 下载权限。"
        case .api(let code):
            switch code {
            case 105, 403, 407: return "没有访问此文件或目录的权限（\(code)）。请检查共享文件夹与 File Station 权限。"
            case 106, 107, 119: return "文件服务登录已失效（\(code)），请重新连接 File Station 后重试。"
            case 408: return "文件或目录已不存在（408），请返回上级并刷新。"
            case 402: return "文件服务正忙（402），请稍后重试。"
            default: return "File Station 返回错误 \(code)，请检查文件状态与账号权限。"
            }
        }
    }
}

struct NASFile: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let isdir: Bool
    let additional: Additional?
    struct Additional: Codable, Hashable {
        let size: Int64?
        let time: FileTime?
    }
    struct FileTime: Codable, Hashable { let mtime: Double? }
    var id: String { path }
    var size: Int64? { additional?.size }
    var modified: Date? { additional?.time?.mtime.map(Date.init(timeIntervalSince1970:)) }
    var icon: String {
        if isdir { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "zip", "7z", "rar", "gz": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw FileStationError.invalidPath }
    }
}

struct NASFilePage: Decodable {
    let total: Int
    let offset: Int
    let files: [NASFile]?
    let shares: [NASFile]?
    var items: [NASFile] { files ?? shares ?? [] }
}

enum FileSort: String, CaseIterable, Identifiable {
    case name, mtime, size
    var id: String { rawValue }
    var title: String { switch self { case .name: return "名称"; case .mtime: return "修改时间"; case .size: return "大小" } }
}

extension SynologyClient {
    func files(path: String?, offset: Int, sort: FileSort = .name, ascending: Bool = true, limit: Int = 100, foldersOnly: Bool = false) async throws -> NASFilePage {
        var fields: [String: Any] = ["offset": offset, "limit": limit, "sort_by": path == nil && sort == .size ? "name" : sort.rawValue,
                                   "sort_direction": ascending ? "asc" : "desc", "additional": ["size", "time"]]
        if let path { try NASFile.validatePath(path); fields["folder_path"] = path; fields["filetype"] = foldersOnly ? "dir" : "all" }
        else { fields["onlywritable"] = false }
        return try await call(api: "SYNO.FileStation.List", method: path == nil ? "list_share" : "list", parameters: fields, version: 2)
    }
    func fileInfo(path: String) async throws -> NASFile {
        try NASFile.validatePath(path)
        let page: FileInfoResponse = try await call(api: "SYNO.FileStation.List", method: "getinfo", parameters: ["path": [path], "additional": ["size", "time"]], version: 2)
        guard let file = page.files.first, file.path == path, !file.isdir else { throw FileStationError.invalidPath }
        return file
    }
    func fileDownloadRequest(path: String) throws -> URLRequest {
        try NASFile.validatePath(path)
        var request = try makeRequest(api: "SYNO.FileStation.Download", method: "download", parameters: ["path": [path], "mode": "download"], version: 2)
        request.timeoutInterval = 60
        return request
    }
}
private struct FileInfoResponse: Decodable { let files: [NASFile] }

@MainActor
final class NASFileBrowserStore: ObservableObject {
    @Published var items: [NASFile] = []
    @Published var total = 0
    @Published var loading = false
    @Published var hasMore = false
    @Published var error: String?
    private var offset = 0
    private var generation = UUID()
    func reset(client: SynologyClient, path: String?, sort: FileSort, ascending: Bool, foldersOnly: Bool = false) async {
        generation = UUID(); items = []; total = 0; offset = 0; hasMore = true; loading = false
        await loadMore(client: client, path: path, sort: sort, ascending: ascending, foldersOnly: foldersOnly)
    }
    func loadMore(client: SynologyClient, path: String?, sort: FileSort, ascending: Bool, foldersOnly: Bool = false) async {
        guard !loading, hasMore else { return }
        let ticket = generation
        loading = true; error = nil
        defer { if ticket == generation { loading = false } }
        do {
            let page = try await client.files(path: path, offset: offset, sort: sort, ascending: ascending, foldersOnly: foldersOnly)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            guard page.offset == offset, page.total >= 0 else { throw NASError.invalidResponse }
            var known = Set(items.map(\.path))
            for file in page.items {
                try NASFile.validatePath(file.path)
                if known.insert(file.path).inserted { items.append(file) }
            }
            total = page.total; offset += page.items.count
            hasMore = offset < total
            if hasMore && page.items.isEmpty { throw NASError.invalidResponse }
        } catch {
            if ticket == generation && !Task.isCancelled { self.error = friendlyError(error) }
        }
    }
}
