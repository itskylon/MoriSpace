import Foundation

struct OneDriveItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let size: Int64?
    let isFolder: Bool
    let modified: Date?
    let mimeType: String?
    let eTag: String?
    let driveID: String?
    let webURL: URL?

    init(id: String, name: String, size: Int64? = nil, isFolder: Bool = false,
         modified: Date? = nil, mimeType: String? = nil, eTag: String? = nil,
         driveID: String? = nil, webURL: URL? = nil) {
        self.id = id; self.name = name; self.size = size; self.isFolder = isFolder
        self.modified = modified; self.mimeType = mimeType; self.eTag = eTag
        self.driveID = driveID; self.webURL = webURL
    }

    private var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { !isFolder && (mimeType?.hasPrefix("image/") == true || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(fileExtension)) }
    var isVideo: Bool { !isFolder && (mimeType?.hasPrefix("video/") == true || ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv"].contains(fileExtension)) }
    var canPlayNatively: Bool { !isFolder && ["mp4", "m4v", "mov"].contains(fileExtension) }
    var icon: String {
        if isFolder { return "folder.fill" }
        if isImage { return "photo" }
        if isVideo { return "film" }
        if mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "wav", "flac"].contains(fileExtension) { return "music.note" }
        if ["zip", "7z", "rar", "gz"].contains(fileExtension) { return "doc.zipper" }
        return fileExtension == "pdf" ? "doc.richtext" : "doc"
    }
}

struct OneDrivePage: Sendable {
    let items: [OneDriveItem]
    let nextLink: URL?
}

struct OneDriveAccount: Codable, Equatable, Sendable {
    let driveID: String
    let displayName: String
}

protocol OneDriveServing: Sendable {
    func account() async throws -> OneDriveAccount
    func children(of itemID: String?, nextLink: URL?) async throws -> OneDrivePage
    func item(id: String) async throws -> OneDriveItem
    func downloadURL(for itemID: String) async throws -> URL
}

enum OneDriveError: LocalizedError, Equatable {
    case invalidClientID, invalidCallback, cancelled, needsLogin, invalidResponse, unsafeURL
    case disconnected, unsupportedShortcut, permissionDenied, notFound, noDownload, throttled, serviceUnavailable
    case configuration, authorization, keychain(Int32), network

    var errorDescription: String? {
        switch self {
        case .invalidClientID: return "请填写有效的 Microsoft Application (client) ID。它是应用注册页面中的 UUID，不是密码或 Client Secret。"
        case .invalidCallback: return "微软登录回调未通过验证，请重新登录，并检查已注册的回调地址。"
        case .cancelled: return "已取消 OneDrive 登录。"
        case .needsLogin: return "OneDrive 登录已失效，请重新连接微软账号。"
        case .invalidResponse: return "OneDrive 返回的数据不完整，请刷新后重试。"
        case .unsafeURL: return "OneDrive 返回了不受支持的地址，已停止请求。请刷新后重试。"
        case .disconnected: return "OneDrive 已断开，请重新连接。"
        case .unsupportedShortcut: return "暂不支持其他网盘或共享库的快捷方式，请在 OneDrive 中打开。"
        case .permissionDenied: return "没有权限读取此 OneDrive 内容。工作或学校账号可能需要管理员同意 Files.Read 权限。"
        case .notFound: return "文件或目录不存在，或此账号尚未开通 OneDrive。请先在网页确认后刷新。"
        case .noDownload: return "此项目没有可读取的文件内容，请在 OneDrive 网页打开。"
        case .throttled: return "OneDrive 请求较频繁，请稍后刷新。"
        case .serviceUnavailable: return "OneDrive 服务暂时不可用，请稍后重试。"
        case .configuration: return "微软应用配置不匹配。请检查 Client ID 和移动、桌面应用回调地址；使用 Outlook 或 Hotmail 时，应用必须支持个人 Microsoft 账号。"
        case .authorization: return "微软授权未完成。请重新登录；工作或学校账号可能需要管理员批准。"
        case .keychain(let status): return "无法安全保存 OneDrive 登录信息（\(status)）。请确认设备已解锁后重试。"
        case .network: return "无法连接微软服务，请检查网络后重试。"
        }
    }
}

// Neither authenticated Graph requests nor token exchanges may follow redirects.
// Download links are returned separately and must be fetched without the Graph bearer.
final class OneDriveNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor OneDriveClient: OneDriveServing {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String
    private let tokenProvider: TokenProvider
    private let session: URLSession
    private var disconnected = false
    private var ownDriveID: String?
    private static let graphRoot = URL(string: "https://graph.microsoft.com/v1.0/me/drive")!
    private static let itemFields = "id,name,size,folder,file,lastModifiedDateTime,eTag,parentReference,webUrl,remoteItem"

    init(tokenProvider: @escaping TokenProvider, configuration: URLSessionConfiguration = .ephemeral) {
        self.tokenProvider = tokenProvider
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: OneDriveNoRedirectDelegate(), delegateQueue: nil)
    }

    func invalidate() {
        disconnected = true
        session.invalidateAndCancel()
    }

    func account() async throws -> OneDriveAccount {
        let url = Self.url(path: [], query: [URLQueryItem(name: "$select", value: "id,name,owner")])
        let drive: DriveResponse = try await get(url)
        guard !drive.id.isEmpty else { throw OneDriveError.invalidResponse }
        ownDriveID = drive.id
        let label = drive.owner?.user?.displayName ?? drive.name ?? "OneDrive"
        return OneDriveAccount(driveID: drive.id, displayName: label.isEmpty ? "OneDrive" : label)
    }

    func children(of itemID: String? = nil, nextLink: URL? = nil) async throws -> OneDrivePage {
        if let itemID { try Self.validateItemID(itemID) }
        let path = itemID.map { ["items", $0, "children"] } ?? ["root", "children"]
        let initial = Self.url(path: path, query: [URLQueryItem(name: "$select", value: Self.itemFields), URLQueryItem(name: "$top", value: "100")])
        if let nextLink { try validateNextLink(nextLink, expectedPath: initial.path, itemID: itemID) }
        let response: ChildrenResponse = try await get(nextLink ?? initial)
        let next: URL?
        if let value = response.nextLink {
            guard let candidate = URL(string: value) else { throw OneDriveError.unsafeURL }
            try validateNextLink(candidate, expectedPath: initial.path, itemID: itemID)
            next = candidate
        } else { next = nil }
        // A remoteItem shortcut belongs to another drive; never use its ID against /me/drive.
        let items = try response.value.filter { $0.remoteItem == nil }.map { try normalized($0) }
        return OneDrivePage(items: items, nextLink: next)
    }

    func item(id: String) async throws -> OneDriveItem {
        try Self.validateItemID(id)
        let response: ItemResponse = try await get(Self.url(path: ["items", id], query: [URLQueryItem(name: "$select", value: Self.itemFields)]))
        return try normalized(response)
    }

    func downloadURL(for itemID: String) async throws -> URL {
        try Self.validateItemID(itemID)
        let fields = Self.itemFields + ",@microsoft.graph.downloadUrl"
        let response: ItemResponse = try await get(Self.url(path: ["items", itemID], query: [URLQueryItem(name: "$select", value: fields)]))
        let file = try normalized(response)
        guard !file.isFolder, let value = response.downloadURL, let url = URL(string: value) else { throw OneDriveError.noDownload }
        try Self.validateDownloadURL(url)
        return url
    }

    static func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { throw OneDriveError.unsafeURL }
    }

    private func normalized(_ response: ItemResponse) throws -> OneDriveItem {
        guard response.remoteItem == nil else { throw OneDriveError.unsupportedShortcut }
        if let ownDriveID, let driveID = response.parentReference?.driveId, driveID != ownDriveID { throw OneDriveError.unsupportedShortcut }
        guard !response.id.isEmpty, !response.name.isEmpty, response.size.map({ $0 >= 0 }) ?? true else { throw OneDriveError.invalidResponse }
        let modified = response.lastModifiedDateTime.flatMap(Self.parseDate)
        let webURL = response.webUrl.flatMap(URL.init(string:)).flatMap { (try? Self.validateDownloadURL($0)) == nil ? nil : $0 }
        return OneDriveItem(id: response.id, name: response.name, size: response.size,
                            isFolder: response.folder != nil, modified: modified, mimeType: response.file?.mimeType,
                            eTag: response.eTag, driveID: response.parentReference?.driveId ?? ownDriveID, webURL: webURL)
    }

    private func validateNextLink(_ url: URL, expectedPath: String, itemID: String?) throws {
        try Self.validateGraphURL(url)
        var permitted = [expectedPath]
        if let ownDriveID {
            let suffix = itemID.map { "/items/\($0)/children" } ?? "/root/children"
            permitted.append("/v1.0/drives/\(ownDriveID)" + suffix)
        }
        guard permitted.contains(url.path), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(parts.queryItems ?? []).contains(where: { !["$skiptoken", "$skipToken", "$skip", "$top", "$select", "$orderby", "$expand"].contains($0.name) }) else {
            throw OneDriveError.unsafeURL
        }
    }

    private static func validateGraphURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "graph.microsoft.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/v1.0/") else { throw OneDriveError.unsafeURL }
    }

    private static func validateItemID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 1024, !id.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" }),
              id != ".", id != "..", !id.contains("%") else { throw OneDriveError.invalidResponse }
    }

    private static func url(path: [String], query: [URLQueryItem]) -> URL {
        let url = path.reduce(graphRoot) { $0.appendingPathComponent($1) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        return parts.url!
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        try Self.validateGraphURL(url)
        try checkActive()
        var token = try await tokenProvider(false)
        for attempt in 0...1 {
            try checkActive()
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch { try checkActive(); throw OneDriveError.network }
            try checkActive()
            guard let http = response as? HTTPURLResponse else { throw OneDriveError.invalidResponse }
            if http.statusCode == 401, attempt == 0 {
                let latest = try await tokenProvider(false)
                token = latest == token ? try await tokenProvider(true) : latest
                continue
            }
            switch http.statusCode {
            case 200...299:
                guard data.count <= 16 * 1024 * 1024 else { throw OneDriveError.invalidResponse }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch { throw OneDriveError.invalidResponse }
            case 401: throw OneDriveError.needsLogin
            case 403: throw OneDriveError.permissionDenied
            case 404: throw OneDriveError.notFound
            case 429: throw OneDriveError.throttled
            case 500...599: throw OneDriveError.serviceUnavailable
            case 300...399: throw OneDriveError.unsafeURL
            default: throw OneDriveError.invalidResponse
            }
        }
        throw OneDriveError.needsLogin
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !disconnected else { throw OneDriveError.disconnected }
    }

    private static func parseDate(_ string: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: string) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: string)
    }

    private struct DriveResponse: Decodable {
        let id: String
        let name: String?
        let owner: Owner?
        struct Owner: Decodable { let user: User? }
        struct User: Decodable { let displayName: String? }
    }
    private struct ChildrenResponse: Decodable {
        let value: [ItemResponse]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
    }
    private struct ItemResponse: Decodable {
        let id: String
        let name: String
        let size: Int64?
        let folder: Folder?
        let file: File?
        let lastModifiedDateTime: String?
        let eTag: String?
        let parentReference: ParentReference?
        let webUrl: String?
        let remoteItem: RemoteItem?
        let downloadURL: String?
        struct Folder: Decodable {}
        struct File: Decodable { let mimeType: String? }
        struct ParentReference: Decodable { let driveId: String? }
        struct RemoteItem: Decodable {}
        enum CodingKeys: String, CodingKey {
            case id, name, size, folder, file, lastModifiedDateTime, eTag, parentReference, webUrl, remoteItem
            case downloadURL = "@microsoft.graph.downloadUrl"
        }
    }
}
