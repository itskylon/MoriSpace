import Foundation
import UIKit
import ImageIO

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor SynologyClient {
    let baseURL: URL
    let service: NASService
    private let session: URLSession
    private var info: [String: APIInfo] = [:]
    private var sid = ""
    private var token: String?
    private var recovery: (@Sendable () async throws -> NASSession)?
    private var renewal: (id: UUID, task: Task<NASSession, Error>)?
    private var sessionGeneration = UUID()
    private var closed = false
    private let thumbnails = NSCache<NSString, UIImage>()

    init(address: String, service: NASService = .photos, session: URLSession? = nil) throws {
        baseURL = try service.baseURL(address)
        self.service = service
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 180
            config.httpMaximumConnectionsPerHost = 4
            config.urlCache = nil
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        thumbnails.totalCostLimit = 48 * 1024 * 1024
    }

    static func normalizedAddress(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw NASError.invalidAddress }
        guard parts.scheme?.lowercased() == "https" else { throw NASError.insecureAddress }
        if host == "quickconnect.to" || host.hasSuffix(".quickconnect.to") { throw NASError.quickConnect }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/webapi") { path = String(path.dropLast(7)) }
        parts.path = path
        guard let url = parts.url else { throw NASError.invalidAddress }
        return url
    }

    func login(_ credentials: NASCredentials, otp: String) async throws {
        try Task.checkCancellation()
        sid = ""; token = nil
        info = try await call(api: "SYNO.API.Info", method: "query", parameters: ["query": "all"], discovery: true)
        let auth = info["SYNO.API.Auth"]
        var parameters: [String: Any] = ["account": credentials.username, "passwd": credentials.password,
                                         "session": service.rawValue, "format": "sid", "enable_syno_token": "yes"]
        if !otp.isEmpty { parameters["otp_code"] = otp }
        let result: LoginResponse = try await call(api: "SYNO.API.Auth", method: "login", parameters: parameters, version: min(auth?.maxVersion ?? 6, 6))
        try Task.checkCancellation()
        guard Self.isCookieValue(result.sid), result.synotoken?.contains(where: { $0.isNewline }) != true else { throw NASError.invalidResponse }
        sid = result.sid
        token = result.synotoken
        sessionGeneration = UUID()
        info = try await call(api: "SYNO.API.Info", method: "query", parameters: ["query": "all"], discovery: true)
        guard info[service.requiredAPI] != nil else { throw service == .files ? FileStationError.unavailable : NASError.unsupported(service.title) }
    }

    func resume(_ saved: NASSession) async throws {
        try apply(saved)
        info = try await call(api: "SYNO.API.Info", method: "query", parameters: ["query": "all"], discovery: true)
        guard info[service.requiredAPI] != nil else { throw service == .files ? FileStationError.unavailable : NASError.unsupported(service.title) }
    }

    func sessionSnapshot() -> NASSession { NASSession(sid: sid, token: token) }
    func setRecovery(_ action: @escaping @Sendable () async throws -> NASSession) { recovery = action }

    private func apply(_ saved: NASSession) throws {
        guard !closed, Self.isCookieValue(saved.sid), saved.token?.contains(where: { $0.isNewline }) != true else { throw NASError.invalidResponse }
        sid = saved.sid; token = saved.token; sessionGeneration = UUID()
    }

    private func recover(failedGeneration: UUID) async throws {
        guard !closed else { throw CancellationError() }
        if sessionGeneration != failedGeneration { return }
        guard let recovery else { throw NASError.api(119) }
        let pending: (id: UUID, task: Task<NASSession, Error>)
        if let renewal { pending = renewal }
        else {
            pending = (UUID(), Task { try await recovery() })
            renewal = pending
        }
        do {
            let next = try await pending.task.value
            guard !closed else { throw CancellationError() }
            if sessionGeneration == failedGeneration { try apply(next) }
            if renewal?.id == pending.id { renewal = nil }
        } catch {
            if renewal?.id == pending.id {
                renewal = nil
                // A failed renewal is surfaced once. Explicit reconnect installs a new client.
                self.recovery = nil
            }
            throw error
        }
    }

    // Release transport resources without invalidating a session saved for the next launch.
    func close() {
        closed = true; renewal?.task.cancel(); renewal = nil; recovery = nil
        sid = ""; token = nil; thumbnails.removeAllObjects()
        session.invalidateAndCancel()
    }

    func logout() async {
        recovery = nil; renewal?.task.cancel()
        if !sid.isEmpty {
            let _: EmptyResponse? = try? await call(api: "SYNO.API.Auth", method: "logout", parameters: ["session": service.rawValue])
        }
        close()
    }

    func photos(space: PhotoSpace, folder: Int? = nil, offset: Int, limit: Int = 90) async throws -> [NASPhoto] {
        var parameters: [String: Any] = ["offset": offset, "limit": limit, "additional": ["thumbnail", "resolution"], "sort_by": "takentime", "sort_direction": "desc"]
        if let folder { parameters["folder_id"] = folder }
        let result: NASList<NASPhoto> = try await call(api: space.api + ".Browse.Item", method: "list", parameters: parameters)
        return result.list
    }

    func folders(space: PhotoSpace, parent: Int? = nil, offset: Int, limit: Int = 100) async throws -> [NASFolder] {
        var parameters: [String: Any] = ["offset": offset, "limit": limit]
        if let parent { parameters["id"] = parent }
        let result: NASList<NASFolder> = try await call(api: space.api + ".Browse.Folder", method: "list", parameters: parameters)
        return result.list
    }

    func thumbnail(_ photo: NASPhoto, space: PhotoSpace, large: Bool = false) async throws -> UIImage {
        let cacheKey = "\(space.rawValue):\(photo.id):\(photo.additional?.thumbnail?.cache_key ?? ""):\(large)" as NSString
        if let cached = thumbnails.object(forKey: cacheKey) { return cached }
        var parameters: [String: Any] = ["id": photo.additional?.thumbnail?.unit_id ?? photo.id, "type": "unit", "size": large ? "xl" : "m"]
        if let key = photo.additional?.thumbnail?.cache_key { parameters["cache_key"] = key }
        let (file, _) = try await media(api: space.api + ".Thumbnail", method: "get", parameters: parameters)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: large ? 2400 : 500, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NASError.invalidImage }
        let result = UIImage(cgImage: image)
        thumbnails.setObject(result, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return result
    }

    func original(_ photo: NASPhoto, space: PhotoSpace) async throws -> URL {
        let (file, _) = try await media(api: space.api + ".Download", method: "download", parameters: ["unit_id": [photo.id]])
        do {
            // A successful API response may still contain a ZIP or unsupported file.
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw NASError.invalidImage }
            let ext = (photo.filename as NSString).pathExtension
            let safeExtension = ext.range(of: "^[a-zA-Z0-9]{1,10}$", options: .regularExpression) != nil ? ext : "jpg"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(safeExtension)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func clearCache() { thumbnails.removeAllObjects() }

    func supportedVersion(api: String, maximum: Int) throws -> Int {
        guard let found = info[api], found.minVersion <= maximum else { throw NASError.unsupported(api) }
        return min(found.maxVersion, maximum)
    }

    func call<T: Decodable>(api: String, method: String, parameters: [String: Any], version: Int = 1, discovery: Bool = false) async throws -> T {
        for attempt in 0...1 {
            let generation = sessionGeneration
            do { return try await callOnce(api: api, method: method, parameters: parameters, version: version, discovery: discovery) }
            catch {
                if attempt == 1 && isExpiredNASSession(error) { recovery = nil }
                guard attempt == 0, !discovery, api != "SYNO.API.Auth", recovery != nil, isExpiredNASSession(error) else { throw error }
                try await recover(failedGeneration: generation)
            }
        }
        throw NASError.api(119)
    }

    private func media(api: String, method: String, parameters: [String: Any]) async throws -> (URL, URLResponse) {
        for attempt in 0...1 {
            let generation = sessionGeneration
            let request = try makeRequest(api: api, method: method, parameters: parameters)
            let (file, response) = try await session.download(for: request)
            do {
                try Self.validateHTTP(response)
                try Self.validateMedia(file: file, response: response)
                return (file, response)
            } catch {
                try? FileManager.default.removeItem(at: file)
                if attempt == 1 && isExpiredNASSession(error) { recovery = nil }
                guard attempt == 0, recovery != nil, isExpiredNASSession(error) else { throw error }
                try await recover(failedGeneration: generation)
            }
        }
        throw NASError.api(119)
    }

    private func callOnce<T: Decodable>(api: String, method: String, parameters: [String: Any], version: Int, discovery: Bool) async throws -> T {
        let request = try makeRequest(api: api, method: method, parameters: parameters, version: version, discovery: discovery)
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response)
        let envelope: APIEnvelope<T>
        do { envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data) }
        catch { throw NASError.invalidResponse }
        guard envelope.success else {
            let code = envelope.error?.code ?? -1
            if api.hasPrefix("SYNO.FileStation.") { throw FileStationError.api(envelope.error?.fileCode ?? code) }
            throw NASError.api(code)
        }
        if let result = envelope.data { return result }
        if let empty = EmptyResponse() as? T { return empty }
        throw NASError.invalidResponse
    }

    func makeRequest(api: String, method: String, parameters: [String: Any], version: Int = 1, discovery: Bool = false) throws -> URLRequest {
        if !discovery {
            guard let found = info[api], version >= found.minVersion, version <= found.maxVersion else {
                throw service == .files ? FileStationError.unavailable : NASError.unsupported(api)
            }
        }
        let path = discovery ? "query.cgi" : (info[api]?.path ?? "entry.cgi")
        // API discovery is untrusted server input: allow only relative CGI paths without traversal or another origin.
        guard path.range(of: "^(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_.-]+\\.cgi$", options: .regularExpression) != nil else { throw NASError.invalidResponse }
        let url = baseURL.appendingPathComponent("webapi").appendingPathComponent(path)
        var fields = [URLQueryItem(name: "api", value: api), URLQueryItem(name: "method", value: method), URLQueryItem(name: "version", value: String(version))]
        let jsonValues = info[api]?.requestFormat == "JSON" && api != "SYNO.API.Auth" && api != "SYNO.API.Info"
        for key in parameters.keys.sorted() {
            let value = parameters[key]!
            let encoded: String
            if jsonValues || value is [String] || value is [Int] {
                encoded = String(data: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)!
            } else { encoded = String(describing: value) }
            fields.append(URLQueryItem(name: key, value: encoded))
        }
        if !sid.isEmpty { fields.append(URLQueryItem(name: "_sid", value: sid)) }
        if let token { fields.append(URLQueryItem(name: "SynoToken", value: token)) }
        var body = URLComponents()
        body.queryItems = fields
        // '+' must be escaped in form bodies, including passwords and filenames.
        let encodedBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // DSM also accepts the session as its `id` cookie. Send it explicitly
        // so Photos can authenticate before parsing a JSON-format API body.
        // The client is restricted to one origin and refuses redirects.
        if !sid.isEmpty { request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie") }
        if let token { request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        request.httpBody = encodedBody?.data(using: .utf8)
        return request
    }

    func uploadBackupOriginal(_ original: BackupOriginal, folder: String, wifiOnly: Bool) async throws {
        try NASFile.validatePath(folder)
        let target = folder + "/" + original.filename
        if try await verifiedBackupExists(path: target, original: original) { return }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let generation = sessionGeneration
            let bodyFile = original.url.deletingLastPathComponent().appendingPathComponent("multipart-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            do {
                var request = try makeRequest(api: "SYNO.FileStation.Upload", method: "upload", parameters: [:], version: 2)
                var form = URLComponents(); form.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
                var fields = (form.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                fields += [("path", folder), ("create_parents", "true"), ("overwrite", "false"), ("crtime", String(Int64(original.created.timeIntervalSince1970 * 1000))), ("mtime", String(Int64(original.created.timeIntervalSince1970 * 1000)))]
                let boundary = "Mori" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let size = try BackupMultipart.write(fields: fields, original: original, to: bodyFile, boundary: boundary)
                request.httpBody = nil
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.setValue(String(size), forHTTPHeaderField: "Content-Length")
                request.allowsCellularAccess = !wifiOnly
                request.allowsExpensiveNetworkAccess = !wifiOnly
                request.allowsConstrainedNetworkAccess = !wifiOnly
                request.timeoutInterval = 120
                let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
                try Self.validateHTTP(response)
                let result: APIEnvelope<EmptyResponse>
                do { result = try JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: data) }
                catch { throw NASError.invalidResponse }
                guard result.success else { throw FileStationError.api(result.error?.fileCode ?? -1) }
                guard try await verifiedBackupExists(path: target, original: original) else { throw PhotoBackupError.verification }
                return
            } catch {
                guard attempt == 0, recovery != nil, isExpiredNASSession(error) else { throw error }
                try await recover(failedGeneration: generation)
            }
        }
    }

    private static func isCookieValue(_ value: String) -> Bool {
        // RFC 6265 cookie-octet: exclude whitespace, quotes, commas,
        // semicolons, backslashes and all control/non-ASCII bytes.
        !value.isEmpty && value.utf8.allSatisfy {
            $0 == 0x21 || (0x23...0x2B).contains($0) || (0x2D...0x3A).contains($0)
                || (0x3C...0x5B).contains($0) || (0x5D...0x7E).contains($0)
        }
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NASError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw NASError.redirect }
        guard (200..<300).contains(http.statusCode) else { throw NASError.http(http.statusCode) }
    }
    private static func validateMedia(file: URL, response: URLResponse) throws {
        if response.mimeType?.contains("json") == true {
            let data = try Data(contentsOf: file)
            if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: data), !envelope.success {
                throw NASError.api(envelope.error?.code ?? -1)
            }
            throw NASError.invalidImage
        }
    }
}
