#if DEBUG && targetEnvironment(simulator)
import Foundation

/// An isolated synthetic Drive for simulator gesture tests. This protocol is
/// installed only in fixture sessions, handles every request, and never falls
/// back to the network or the Google Sign-In SDK.
final class GoogleDriveFixture: URLProtocol {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--google-drive-fixture") }
    static let owner = "google-drive:simulator-gesture-fixture"
    static let token = "simulator-fixture-only"

    static func configuration() -> URLSessionConfiguration {
        let result = URLSessionConfiguration.ephemeral
        result.protocolClasses = [GoogleDriveFixture.self]
        return result
    }

    private static func file(_ id: String, _ name: String, folder: Bool = false) -> [String: Any] {
        ["id": id, "name": name,
         "mimeType": folder ? "application/vnd.google-apps.folder" : "text/plain",
         "size": folder ? "0" : "128", "modifiedTime": "2026-10-19T00:00:00Z",
         "capabilities": ["canDownload": !folder]]
    }

    private static func reply(_ request: URLRequest) throws -> (Int, Data) {
        guard let url = request.url, url.scheme == "https", url.host == "www.googleapis.com",
              url.path == "/drive/v3/files", request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.queryItems?.first(where: { $0.name == "q" })?.value else {
            return (404, Data("{}".utf8))
        }
        let files: [[String: Any]]
        switch query {
        case "trashed = false and ('root' in parents)":
            files = [file("fixture-folder", "旅行", folder: true), file("fixture-root-file", "根目录说明.txt")]
        case "trashed = false and ('fixture-folder' in parents)":
            files = [file("fixture-child", "2026", folder: true)] + (1...60).map {
                file("fixture-travel-\($0)", String(format: "旅行记录 %02d.txt", $0))
            }
        case "trashed = false and ('fixture-child' in parents)":
            files = (1...60).map { file("fixture-child-file-\($0)", String(format: "2026 照片说明 %02d.txt", $0)) }
        default:
            return (404, Data("{}".utf8))
        }
        return (200, try JSONSerialization.data(withJSONObject: ["files": files]))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, bytes) = try Self.reply(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badURL)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
