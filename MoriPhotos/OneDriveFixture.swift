#if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
import Foundation

// Synthetic, offline-only account used by simulator and desktop UI tests.
enum OneDriveFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--onedrive-fixture") }
    static let text = Data("欢迎使用森空间 OneDrive。\n这是一份仅供界面验收的示例文件。\n".utf8)
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLl8AAAAASUVORK5CYII=")!
    static let account = OneDriveAccount(driveID: "fixture-drive", displayName: "示例 OneDrive")

    @MainActor static func session() -> OneDriveSession {
        let suite = "dev.kylon.MoriPhotos.onedrive.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OneDriveSession(client: OneDriveFixtureClient(), account: account, defaults: defaults)
    }
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveFixtureURLProtocol.self]
        return configuration
    }
    static func downloadURL(_ id: String) -> URL {
        URL(string: "https://onedrive-fixture.example.invalid/content/" + id)!
    }
    static func item(_ id: String, name: String, folder: Bool = false, bytes: Int? = nil, mime: String? = nil) throws -> OneDriveItem {
        OneDriveItem(id: id, name: name, size: bytes.map(Int64.init), isFolder: folder,
                     modified: Date(timeIntervalSince1970: 1_789_804_800), mimeType: mime,
                     eTag: "fixture-" + id, driveID: "fixture-drive",
                     webURL: URL(string: "https://onedrive.live.com/?id=fixture-" + id))
    }
}

private actor OneDriveFixtureClient: OneDriveServing {
    func account() async throws -> OneDriveAccount { OneDriveFixture.account }
    func children(of id: String?, nextLink: URL?) async throws -> OneDrivePage {
        let items: [OneDriveItem]
        switch id {
        case nil:
            items = [
                try OneDriveFixture.item("photos", name: "Photos", folder: true),
                try OneDriveFixture.item("documents", name: "Documents", folder: true),
                try OneDriveFixture.item("welcome", name: "welcome.txt", bytes: OneDriveFixture.text.count, mime: "text/plain")
            ]
        case "photos":
            items = [
                try OneDriveFixture.item("archive", name: "示例归档", folder: true),
                try OneDriveFixture.item("sample", name: "示例色块.png", bytes: OneDriveFixture.image.count, mime: "image/png")
            ]
        case "documents":
            items = [try OneDriveFixture.item("readme", name: "使用说明.txt", bytes: OneDriveFixture.text.count, mime: "text/plain")]
        case "archive": items = []
        default: throw URLError(.fileDoesNotExist)
        }
        return OneDrivePage(items: items, nextLink: nil)
    }
    func item(id: String) async throws -> OneDriveItem {
        for folder: String? in [nil, "photos", "documents"] {
            if let item = try await children(of: folder, nextLink: nil).items.first(where: { $0.id == id }) { return item }
        }
        throw URLError(.fileDoesNotExist)
    }
    func downloadURL(for id: String) async throws -> URL {
        guard ["welcome", "readme", "sample"].contains(id) else { throw URLError(.fileDoesNotExist) }
        return OneDriveFixture.downloadURL(id)
    }
}

private final class OneDriveFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
        }
        guard let url = request.url, url.host == "onedrive-fixture.example.invalid",
              ["/content/welcome", "/content/readme", "/content/sample"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let image = url.path == "/content/sample"
        let data = image ? OneDriveFixture.image : OneDriveFixture.text
        let headers = ["Content-Type": image ? "image/png" : "text/plain; charset=utf-8", "Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
