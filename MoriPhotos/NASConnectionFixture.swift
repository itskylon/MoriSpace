#if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
import UIKit

// Synthetic account and images for connection UI acceptance; excluded from physical-device builds.
final class NASConnectionFixture: URLProtocol {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--nas-connection-fixture") || ProcessInfo.processInfo.arguments.contains("--empty-connection-fixture") }
    private static var recordURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MoriConnectionUITest.json") }
    @MainActor static func persistence() -> ConnectionPersistence {
        if ProcessInfo.processInfo.arguments.contains("--empty-connection-fixture") {
            return ConnectionPersistence(load: { nil }, save: { _ in }, delete: {})
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-nas-connection-fixture") {
            let saved = SavedNASConnection(credentials: FileStationFixture.credentials)
            try? JSONEncoder().encode(saved).write(to: recordURL, options: .atomic)
        }
        return ConnectionPersistence(load: {
            guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
            return try SavedNASConnection.decode(Data(contentsOf: recordURL))
        }, save: { try JSONEncoder().encode($0).write(to: recordURL, options: .atomic) }, delete: {
            try? FileManager.default.removeItem(at: recordURL)
        })
    }
    static func makeClient(_ credentials: NASCredentials, service: NASService) throws -> SynologyClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NASConnectionFixture.self]
        return try SynologyClient(address: credentials.address, service: service, session: URLSession(configuration: config))
    }
    static func reply(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let fields = FileStationFixture.fields(request), api = FileStationFixture.fields(request)["api"] ?? ""
        var object: [String: Any] = ["success": true]
        if api == "SYNO.API.Info" {
            var info = FileStationFixture.info
            for prefix in ["SYNO.Foto", "SYNO.FotoTeam"] {
                for suffix in ["Browse.Item", "Browse.Folder", "Thumbnail", "Download"] {
                    info[prefix + "." + suffix] = ["path": "entry.cgi", "minVersion": 1, "maxVersion": 4, "requestFormat": "JSON"]
                }
            }
            info.merge(NASMonitorFixture.info) { _, new in new }
            object["data"] = info
        } else if fields["method"] == "login", ProcessInfo.processInfo.arguments.contains("--require-resumed-sessions") {
            object = ["success": false, "error": ["code": 400]]
        } else if let data = NASMonitorFixture.response(api: api) {
            guard request.value(forHTTPHeaderField: "Cookie") == "id=file-test-session" else {
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": 119]]))
            }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--monitor-all-denied") || (args.contains("--monitor-partial-permission") && api != "SYNO.Core.System") {
                object = ["success": false, "error": ["code": 105]]
            } else { object["data"] = data }
        } else if api.hasPrefix("SYNO.Foto") {
            guard request.value(forHTTPHeaderField: "Cookie") == "id=file-test-session" else {
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": 119]]))
            }
            if api.hasSuffix("Thumbnail") {
                let id = Int(fields["id"] ?? "1") ?? 1
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 480), format: format).image { context in
                    UIColor(hue: CGFloat(id % 9) / 9, saturation: 0.38, brightness: 0.78, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
                    UIColor.white.withAlphaComponent(0.3).setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 45, y: 55, width: 190, height: 190))
                    UIColor.black.withAlphaComponent(0.12).setFill()
                    context.cgContext.fill(CGRect(x: 0, y: 310, width: 480, height: 170))
                }
                return (200, ["Content-Type": "image/png"], image.pngData()!)
            }
            if api.hasSuffix("Item") {
                object["data"] = ["list": (1...12).map { id -> [String: Any] in
                    var item: [String: Any] = ["id": id, "filename": "测试照片-\(id).png"]
                    if id == 1 { item["filesize"] = 3_200_000 }
                    else if id == 2 { item["filesize"] = 850_000 }
                    return item
                }]
            } else {
                let folders: [[String: Any]] = fields["id"] == nil ? [
                    ["id": 101, "name": "/MobileBackup", "parent": 0],
                    ["id": 102, "name": "/PhotoLibrary", "parent": 0],
                    ["id": 103, "name": "/一个用于检查完整文件夹名称显示的测试目录", "parent": 0]
                ] : []
                object["data"] = ["list": folders]
            }
        } else { return try FileStationFixture.reply(request) }
        return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: object))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

enum NASMonitorFixture {
    static let info: [String: [String: Any]] = [
        "SYNO.Core.System": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 3, "requestFormat": "JSON"],
        "SYNO.Core.System.Utilization": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 1, "requestFormat": "JSON"],
        "SYNO.Storage.CGI.Storage": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 1, "requestFormat": "JSON"]
    ]
    static func response(api: String) -> [String: Any]? {
        switch api {
        case "SYNO.Core.System": return ["model": "DS923+", "firmware_ver": "DSM 7.2.2", "sys_temp": 42, "sys_tempwarn": false, "up_time": "296:25:09"]
        case "SYNO.Core.System.Utilization": return [
            "cpu": ["user_load": 12, "system_load": 4, "other_load": 2],
            "memory": ["real_usage": 36, "memory_size": 8_388_608],
            "network": [["device": "total", "rx": 1_572_864, "tx": 524_288], ["device": "eth0", "rx": 1_572_864, "tx": 524_288]]
        ]
        case "SYNO.Storage.CGI.Storage": return [
            "volumes": [["id": "volume_1", "status": "normal", "size": ["total": "8796093022208", "used": "3958241859993"]]],
            "disks": [
                ["id": "disk1", "name": "硬盘 1", "temp": 36, "overview_status": "normal", "smart_status": "normal", "status": "normal"],
                ["id": "disk2", "name": "硬盘 2", "temp": 37, "overview_status": "normal", "smart_status": "normal", "status": "normal"]
            ]
        ]
        default: return nil
        }
    }
}
#endif
