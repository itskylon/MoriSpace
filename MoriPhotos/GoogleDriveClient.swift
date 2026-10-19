import Foundation

struct GoogleDriveExport: Equatable, Sendable {
    let mimeType: String
    let fileExtension: String
}

struct GoogleDriveFile: Codable, Hashable, Identifiable, Sendable {
    struct Capabilities: Codable, Hashable, Sendable { var canDownload: Bool? }
    let id: String
    let name: String
    let mimeType: String
    var size: Int64?
    var modifiedTime: Date?
    var capabilities: Capabilities?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var exportFormat: GoogleDriveExport? {
        switch mimeType {
        case "application/vnd.google-apps.document": .init(mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileExtension: "docx")
        case "application/vnd.google-apps.spreadsheet": .init(mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileExtension: "xlsx")
        case "application/vnd.google-apps.presentation": .init(mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", fileExtension: "pptx")
        case "application/vnd.google-apps.drawing": .init(mimeType: "application/pdf", fileExtension: "pdf")
        default: nil
        }
    }
    var canDownload: Bool {
        !isFolder && capabilities?.canDownload != false && (!mimeType.hasPrefix("application/vnd.google-apps.") || exportFormat != nil)
    }
    var symbol: String {
        if isFolder { return "folder.fill" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "video" }
        if mimeType.hasPrefix("audio/") { return "music.note" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        if mimeType.contains("spreadsheet") { return "tablecells" }
        if mimeType.contains("presentation") { return "rectangle.on.rectangle" }
        if mimeType == "application/vnd.google-apps.shortcut" { return "arrow.turn.up.right" }
        return "doc"
    }
    private enum CodingKeys: String, CodingKey { case id, name, mimeType, size, modifiedTime, capabilities }
    init(id: String, name: String, mimeType: String, size: Int64? = nil, modifiedTime: Date? = nil, capabilities: Capabilities? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size
        self.modifiedTime = modifiedTime; self.capabilities = capabilities
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        if let text = try? values.decode(String.self, forKey: .size) { size = Int64(text) }
        else { size = try values.decodeIfPresent(Int64.self, forKey: .size) }
        modifiedTime = try values.decodeIfPresent(Date.self, forKey: .modifiedTime)
        capabilities = try values.decodeIfPresent(Capabilities.self, forKey: .capabilities)
    }
}

struct GoogleDrivePage: Decodable, Sendable {
    let files: [GoogleDriveFile]
    let nextPageToken: String?
}

enum GoogleDriveError: LocalizedError, Equatable {
    case signInRequired, invalidResponse, invalidID, forbidden, notFound, rateLimited, apiDisabled
    case http(Int), redirect, incomplete, notDownloadable, exportTooLarge, noSpace
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Google 授权已失效或未授予云盘读取权限，请重新连接 Google Drive。"
        case .invalidResponse: "Google Drive 返回了无法识别的数据，请稍后重试。"
        case .invalidID: "这个 Google Drive 文件标识无效。"
        case .forbidden: "没有读取或下载此文件的权限，或该文件已被所有者限制下载。"
        case .notFound: "文件不存在、已被移走，或当前 Google 账号没有访问权限。"
        case .rateLimited: "Google Drive 请求过于频繁或已达到下载额度，请稍后重试。"
        case .apiDisabled: "此 Google 应用尚未启用 Google Drive API，请在 Google Cloud 中启用后重试。"
        case .http(let code): "Google Drive 暂时无法完成请求（HTTP \(code)）。"
        case .redirect: "Google Drive 返回了下载重定向，本次下载已安全停止。请在 Google Drive 网页中打开此文件。"
        case .incomplete: "文件下载不完整，请重新下载。"
        case .notDownloadable: "此文件暂不支持下载。Google 原生文档仅支持文档、表格、幻灯片和绘图导出。"
        case .exportTooLarge: "此 Google 文档超过 API 的 10 MB 导出限制，请在 Google Drive 网页中导出。"
        case .noSpace: "本机存储空间不足，无法下载这个文件。"
        }
    }
}

func googleDriveErrorMessage(_ error: Error) -> String {
    if let error = error as? GoogleDriveAuthError { return error.localizedDescription }
    if let error = error as? GoogleDriveError { return error.localizedDescription }
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "操作已取消。" }
    if let error = error as? URLError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: return "网络连接已断开，请检查网络或 VPN 后重试 Google Drive。"
        case .timedOut: return "连接 Google Drive 超时，请检查网络或 VPN 后重试。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "暂时无法连接 Google Drive，请检查网络与 DNS。"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed: return "无法验证 Google Drive 的安全连接，请检查设备时间和网络。"
        default: return "连接 Google Drive 失败，请检查网络后重试。"
        }
    }
    // Do not display OAuth response bodies, tokens, or arbitrary server messages.
    return "无法完成 Google Drive 操作，请重试。"
}

private final class GoogleDriveRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class GoogleDriveClient: @unchecked Sendable {
    let accountID: String
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let transferConfiguration: @Sendable () -> URLSessionConfiguration
    static let fileFields = "id,name,mimeType,size,modifiedTime,capabilities(canDownload)"

    @MainActor convenience init(auth: GoogleDriveAuth) {
        let owner = auth.accountID ?? ""
        let provider: @Sendable () async throws -> String = {
            guard await auth.accountID == owner, !owner.isEmpty else { throw GoogleDriveError.signInRequired }
            let token = try await auth.accessToken()
            guard await auth.accountID == owner else { throw GoogleDriveError.signInRequired }
            return token
        }
        #if DEBUG && targetEnvironment(simulator)
        if GoogleDriveFixture.enabled {
            self.init(accountID: owner, tokenProvider: provider, configuration: GoogleDriveFixture.configuration(),
                      transferConfiguration: { GoogleDriveFixture.configuration() })
            return
        }
        #endif
        self.init(accountID: owner, tokenProvider: provider)
    }
    init(accountID: String, tokenProvider: @escaping @Sendable () async throws -> String,
         configuration: URLSessionConfiguration = .ephemeral,
         transferConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.accountID = accountID; self.tokenProvider = tokenProvider; self.transferConfiguration = transferConfiguration
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: GoogleDriveRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func list(folderID: String = "root", search: String = "", pageToken: String? = nil) async throws -> GoogleDrivePage {
        try Self.validateID(folderID)
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = text.isEmpty ? "'\(Self.escapeQuery(folderID))' in parents" : "name contains '\(Self.escapeQuery(text))'"
        var parameters = ["q": "trashed = false and (\(filter))", "spaces": "drive", "pageSize": "100",
                          "fields": "nextPageToken,files(\(Self.fileFields))", "orderBy": "folder,name_natural",
                          "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"]
        if let pageToken { parameters["pageToken"] = pageToken }
        return try Self.decoder().decode(GoogleDrivePage.self, from: await data(path: "files", parameters: parameters))
    }
    func fileInfo(id: String) async throws -> GoogleDriveFile {
        try Self.validateID(id)
        return try Self.decoder().decode(GoogleDriveFile.self, from: await data(path: "files/\(id)", parameters: ["fields": Self.fileFields, "supportsAllDrives": "true"]))
    }
    func download(_ file: GoogleDriveFile, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try Self.validateID(file.id)
        guard file.canDownload else { throw GoogleDriveError.notDownloadable }
        let path: String, parameters: [String: String]
        if let export = file.exportFormat { path = "files/\(file.id)/export"; parameters = ["mimeType": export.mimeType] }
        else { path = "files/\(file.id)"; parameters = ["alt": "media", "supportsAllDrives": "true"] }
        let request = try await request(path: path, parameters: parameters)
        let operation = FileTransfer(configuration: transferConfiguration(), progress: progress)
        let (url, response) = try await operation.run(request)
        do {
            try Task.checkCancellation()
            if !(200..<300).contains(response.statusCode) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let body = size <= 1_048_576 ? (try? Data(contentsOf: url)) : nil
                throw Self.responseError(status: response.statusCode, data: body)
            }
            let count = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if file.exportFormat == nil, let expected = file.size, expected != count { throw GoogleDriveError.incomplete }
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    private func data(path: String, parameters: [String: String]) async throws -> Data {
        let (bytes, response) = try await session.data(for: request(path: path, parameters: parameters))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Self.responseError(status: response.statusCode, data: bytes) }
        return bytes
    }
    private func request(path: String, parameters: [String: String]) async throws -> URLRequest {
        let token = try await tokenProvider()
        try Task.checkCancellation()
        guard !token.isEmpty else { throw GoogleDriveError.signInRequired }
        var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw GoogleDriveError.invalidID }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    static func escapeQuery(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
    static func validateID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1024,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { throw GoogleDriveError.invalidID }
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Drive timestamp"))
        }
        return decoder
    }
    static func responseError(status: Int, data: Data?) -> GoogleDriveError {
        struct Envelope: Decodable {
            struct Body: Decodable { struct Detail: Decodable { let reason: String? }; let errors: [Detail]? }
            let error: Body
        }
        let reasons = data.flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }?.error.errors?.compactMap(\.reason) ?? []
        if reasons.contains("accessNotConfigured") || reasons.contains("serviceDisabled") { return .apiDisabled }
        if reasons.contains("exportSizeLimitExceeded") { return .exportTooLarge }
        if reasons.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "downloadQuotaExceeded", "dailyLimitExceeded"].contains($0) }) { return .rateLimited }
        switch status {
        case 401: return .signInRequired
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        case 300..<400: return .redirect
        default: return .http(status)
        }
    }
}
