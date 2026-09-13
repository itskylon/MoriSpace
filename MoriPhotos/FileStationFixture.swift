#if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
import Foundation

// Isolated synthetic server for UI/integration tests. Never compiled into the iPhone app.
final class FileStationFixture: URLProtocol {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--files-fixture") }
    static var offline: Bool { ProcessInfo.processInfo.arguments.contains("--files-fixture-offline") }
    static let credentials = NASCredentials(address: "https://files.example.invalid:5001", username: "simulator-test", password: "fixture-only")
    static var videoURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MoriVideoTestFixture.mp4") }
    static var videoMode: Bool { ProcessInfo.processInfo.arguments.contains("--video-fixture") }
    static var videoData: Data { (try? Data(contentsOf: videoURL)) ?? Data() }
    static let contents = Data("森相册文件下载验收\n中文 + 空格 & 文件名\nThis file was downloaded byte for byte.\n".utf8)
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileStationFixture.self]; return config
    }
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoriFilesUITestDownloads")
        if ProcessInfo.processInfo.arguments.contains("--reset-files-fixture") { try? FileManager.default.removeItem(at: url) }
        return url
    }
    static let info: [String: Any] = [
        "SYNO.API.Auth": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 7],
        "SYNO.FileStation.List": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 2, "requestFormat": "JSON"],
        "SYNO.FileStation.Download": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 2, "requestFormat": "JSON"],
        "SYNO.FileStation.Upload": ["path": "entry.cgi", "minVersion": 2, "maxVersion": 3],
        "SYNO.FileStation.MD5": ["path": "entry.cgi", "minVersion": 2, "maxVersion": 2, "requestFormat": "JSON"],
        "SYNO.FileStation.CheckPermission": ["path": "entry.cgi", "minVersion": 3, "maxVersion": 3, "requestFormat": "JSON"]
    ]
    static func fields(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: data, encoding: .utf8)
        let urlItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: ((parts.queryItems ?? []) + urlItems).map { ($0.name, $0.value ?? "") })
    }
    static func file(_ name: String, path: String? = nil, folder: Bool = false) -> [String: Any] {
        ["name": name, "path": path ?? "/测试共享/" + name, "isdir": folder, "additional": ["size": folder ? 0 : name.hasSuffix(".mp4") ? videoData.count : contents.count, "time": ["mtime": 1_700_000_000]]]
    }
    static func reply(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let f = fields(request)
        let method = f["method"] ?? ""
        var object: [String: Any] = ["success": true]
        if f["api"] == "SYNO.API.Info" { object["data"] = info }
        else if method == "login" { object["data"] = ["sid": "file-test-session", "synotoken": "file-test-token"] }
        else if method == "logout" { object["data"] = [:] }
        else if request.value(forHTTPHeaderField: "Cookie") != "id=file-test-session" || request.value(forHTTPHeaderField: "X-SYNO-TOKEN") != "file-test-token" { object = ["success": false, "error": ["code": 119]] }
        else if f["api"] == "SYNO.FileStation.CheckPermission" {
            if f["path"]?.contains("无权限") == true { object = ["success": false, "error": ["code": 407]] }
        }
        else if method == "download" {
            let paths = try JSONDecoder().decode([String].self, from: Data((f["path"] ?? "[]").utf8))
            let video = paths.first?.hasSuffix(".mp4") == true
            let data = video ? videoData : contents
            if video, let header = request.value(forHTTPHeaderField: "Range"), !paths.contains(where: { $0.contains("无分段") }) {
                let parts = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
                let start = Int(parts[0])!, end = min(Int(parts[1])!, data.count - 1)
                guard start >= 0, end >= start else { return (416, [:], Data()) }
                let chunk = data.subdata(in: start..<(end + 1))
                return (206, ["Content-Type": "video/mp4", "Content-Range": "bytes \(start)-\(end)/\(data.count)", "Content-Length": String(chunk.count)], chunk)
            }
            return (200, ["Content-Type": video ? "video/mp4" : "application/octet-stream", "Content-Disposition": "attachment; filename=test.txt", "Content-Length": String(data.count)], data)
        } else if method == "getinfo" {
            let paths = try JSONDecoder().decode([String].self, from: Data((f["path"] ?? "[]").utf8))
            object["data"] = ["files": paths.map { file(($0 as NSString).lastPathComponent, path: $0) }]
        } else if method == "list_share" { object["data"] = ["total": 1, "offset": 0, "shares": [file("测试共享", path: "/测试共享", folder: true)]] }
        else {
            let path = try JSONDecoder().decode(String.self, from: Data((f["folder_path"] ?? "\"\"").utf8))
            if path == "/测试共享/无权限" { object = ["success": false, "error": ["code": 407]] }
            else {
                var entries: [[String: Any]] = path == "/测试共享" ? (videoMode ? [file("测试视频.mp4"), file("无分段.mp4")] : []) + [file("空文件夹", folder: true), file("无权限", folder: true), file("说明 + 中文.txt")] + (1...102).map { file("样本-\($0).bin") } : []
                if f["filetype"] == "\"dir\"" { entries = entries.filter { $0["isdir"] as? Bool == true } }
                let offset = Int(f["offset"] ?? "0") ?? 0, limit = Int(f["limit"] ?? "100") ?? 100
                object["data"] = ["files": Array(entries.dropFirst(offset).prefix(limit)), "total": entries.count, "offset": offset]
            }
        }
        return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: object))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
