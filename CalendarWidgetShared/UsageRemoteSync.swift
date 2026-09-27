import Foundation
import Security
import Darwin

enum UsageRemoteError: Error, LocalizedError {
    case invalidConfiguration, unsupportedVersion, invalidAddress, invalidReadToken, oversizedConfiguration
    case unavailableKeychainGroup, keychainFailure, invalidResponse, oversizedResponse, unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "同步配置格式不正确，只能包含版本、服务器地址和读取凭证。"
        case .unsupportedVersion: return "暂不支持这个同步配置版本。"
        case .invalidAddress: return "请输入有效的 HTTPS 同步地址，不能包含账号、查询参数或片段。"
        case .invalidReadToken: return "读取凭证必须是 64 位十六进制字符。"
        case .oversizedConfiguration: return "同步配置文件过大。"
        case .unavailableKeychainGroup: return "此版本未配置额度同步的共享钥匙串。"
        case .keychainFailure: return "无法访问额度同步的系统钥匙串。"
        case .invalidResponse: return "同步服务没有返回有效的额度记录。"
        case .oversizedResponse: return "同步服务返回的记录过大。"
        case .unauthorized: return "读取凭证无效或已失效，请重新导入同步配置。"
        }
    }
}

/// Phone configuration deliberately has no publisher/write credential.
struct UsageRemoteConfiguration: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumFileSize = 4_096
    let version: Int
    let baseURL: String
    let readToken: String
    private enum CodingKeys: String, CodingKey { case version, baseURL, readToken }

    init(version: Int = 1, baseURL: String, readToken: String) throws {
        guard version == 1 else { throw UsageRemoteError.unsupportedVersion }
        guard readToken.utf8.count == 64, readToken.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw UsageRemoteError.invalidReadToken
        }
        self.version = version
        self.baseURL = try Self.normalizedBaseURL(baseURL).absoluteString
        self.readToken = readToken
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: UsageConfigurationKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(["version", "baseURL", "readToken"]) else {
            throw UsageRemoteError.invalidConfiguration
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version),
                      baseURL: values.decode(String.self, forKey: .baseURL),
                      readToken: values.decode(String.self, forKey: .readToken))
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumFileSize else { throw UsageRemoteError.oversizedConfiguration }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as UsageRemoteError { throw error }
        catch { throw UsageRemoteError.invalidConfiguration }
    }

    func validated() throws -> Self { try Self(version: version, baseURL: baseURL, readToken: readToken) }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumFileSize else { throw UsageRemoteError.oversizedConfiguration }
        return data
    }

    var endpointURL: URL {
        // Construction validated and normalized the base. Appending path components keeps its subpath.
        URL(string: baseURL)!.appendingPathComponent("v1", isDirectory: true).appendingPathComponent("usage", isDirectory: false)
    }
    var description: String { "UsageRemoteConfiguration(baseURL: \(baseURL), readToken: <redacted>)" }
    var debugDescription: String { description }

    private static func normalizedBaseURL(_ address: String) throws -> URL {
        guard !address.isEmpty, address.utf8.count <= 2_048,
              address == address.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: address), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else { throw UsageRemoteError.invalidAddress }
        let encodedPath = components.percentEncodedPath.lowercased()
        guard !encodedPath.contains("%2f"), !encodedPath.contains("%5c"), !components.path.contains("\\"),
              !components.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !components.path.contains("//") else { throw UsageRemoteError.invalidAddress }
        components.scheme = "https"
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let result = components.url, result.host != nil else { throw UsageRemoteError.invalidAddress }
        return result
    }
}

private struct UsageConfigurationKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Separate from NAS/OneDrive credentials; never writes a token into the App Group cache.
enum UsageRemoteKeychain {
    static func load() throws -> UsageRemoteConfiguration? { try UsageRemoteKeychainStore().load() }
    static func save(_ configuration: UsageRemoteConfiguration) throws { try UsageRemoteKeychainStore().save(configuration) }
    static func delete() throws { try UsageRemoteKeychainStore().delete() }
}

struct UsageRemoteKeychainStore {
    let accessGroup: String?
    private let operations: UsageRemoteKeychainOperations

    init(accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "MoriUsageKeychainGroup") as? String,
         operations: UsageRemoteKeychainOperations = .system) {
        self.accessGroup = accessGroup
        self.operations = operations
    }

    func save(_ configuration: UsageRemoteConfiguration) throws {
        let data = try configuration.encoded()
        let query = try baseQuery()
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = operations.update(query, changes)
        if status == errSecItemNotFound {
            var item = query
            item.merge(changes) { _, new in new }
            try check(operations.add(item))
        } else { try check(status) }
    }

    func load() throws -> UsageRemoteConfiguration? {
        var query = try baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data else { throw UsageRemoteError.keychainFailure }
        return try UsageRemoteConfiguration.decode(data)
    }

    func delete() throws {
        let status = operations.delete(try baseQuery())
        if status != errSecItemNotFound { try check(status) }
    }

    private func baseQuery() throws -> [String: Any] {
        guard let accessGroup, !accessGroup.isEmpty, accessGroup.utf8.count <= 255,
              accessGroup.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw UsageRemoteError.unavailableKeychainGroup
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.kylon.MoriPhotos.usage.remote",
                kSecAttrAccount as String: "reader-v1",
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw UsageRemoteError.keychainFailure }
    }
}

struct UsageRemoteKeychainOperations {
    let add: ([String: Any]) -> OSStatus
    let update: ([String: Any], [String: Any]) -> OSStatus
    let copy: ([String: Any]) -> (OSStatus, Data?)
    let delete: ([String: Any]) -> OSStatus
    static let system = Self(add: { SecItemAdd($0 as CFDictionary, nil) },
                             update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
                             copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }, delete: { SecItemDelete($0 as CFDictionary) })
}

enum UsageRemoteClient {
    static let maximumResponseBytes = 65_536
    static func fetch(configuration: UsageRemoteConfiguration,
                      sessionConfiguration: URLSessionConfiguration = .ephemeral,
                      now: () -> Date = { Date() }) async throws -> UsageWidgetSnapshot {
        let account = try configuration.validated()
        // Copy the injected test configuration; security policy is still enforced by this client.
        let settings = sessionConfiguration.copy() as! URLSessionConfiguration
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 8
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil; settings.urlCredentialStorage = nil; settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.httpAdditionalHeaders = nil
        let session = URLSession(configuration: settings, delegate: UsageRemoteRequestDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: account.endpointURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + account.readToken, forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageRemoteError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageRemoteError.unauthorized }
        guard http.statusCode == 200, http.url == account.endpointURL,
              http.url?.scheme?.lowercased() == "https", http.mimeType?.lowercased() == "application/json" else {
            throw UsageRemoteError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw UsageRemoteError.oversizedResponse }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maximumResponseBytes))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw UsageRemoteError.oversizedResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try UsageWidgetSnapshot.decode(data, now: now())
    }
}

final class UsageRemoteRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal system certificate verification. Reject HTTP/client-certificate authentication.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Serialize configuration commits with the widget's final identity check + cache write.
/// Never hold this lock across an asynchronous network request. Lock order: configuration, then cache.
enum UsageRemoteTransaction {
    static func withLock<T>(cache: UsageWidgetCache = .shared, _ operation: () throws -> T) throws -> T {
        guard let fileURL = cache.fileURL else { throw UsageWidgetError.unavailableContainer }
        let descriptor = open(fileURL.appendingPathExtension("configuration.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
