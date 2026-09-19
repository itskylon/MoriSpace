import XCTest
@testable import MoriPhotos

/// Deliberately completes even a cancelled request to exercise stale-response protection.
private actor DeferredOneDriveBrowser: OneDriveServing {
    private var requestedIDs: [String] = []
    private var pending: [Int: CheckedContinuation<OneDrivePage, Error>] = [:]
    var requestCount: Int { requestedIDs.count }

    func account() async throws -> OneDriveAccount { .init(driveID: "browser-test-drive", displayName: "示例") }
    func item(id: String) async throws -> OneDriveItem { .init(id: id, name: id) }
    func downloadURL(for itemID: String) async throws -> URL { throw OneDriveError.noDownload }
    func children(of itemID: String?, nextLink: URL?) async throws -> OneDrivePage {
        let id = itemID ?? "root"
        requestedIDs.append(id)
        let number = requestedIDs.count
        return try await withCheckedThrowingContinuation { continuation in
            pending[number] = continuation
        }
    }
    func waitForRequest(_ number: Int) async -> String {
        for _ in 0..<200 {
            if requestedIDs.count >= number { return requestedIDs[number - 1] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected synthetic directory request \(number)")
        return "missing-request"
    }
    func complete(_ number: Int, items: [OneDriveItem]) {
        pending.removeValue(forKey: number)?.resume(returning: OneDrivePage(items: items, nextLink: nil))
    }
}

@MainActor final class OneDriveBrowserTests: XCTestCase {
    func testCancelledFirstLoadCanRestartBeforeItsLateResponseArrives() async {
        let suite = "OneDriveBrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OneDriveBrowserStore(defaults: defaults)
        let client = DeferredOneDriveBrowser()
        let first = Task { await store.start(client: client, accountID: "browser-test-drive") }
        let firstFolder = await client.waitForRequest(1)
        XCTAssertEqual(firstFolder, "root")
        first.cancel()

        let reentry = Task { await store.start(client: client, accountID: "browser-test-drive") }
        let secondFolder = await client.waitForRequest(2)
        XCTAssertEqual(secondFolder, "root")
        await client.complete(2, items: [.init(id: "fresh", name: "Fresh.txt")])
        await reentry.value
        XCTAssertEqual(store.items.map(\.id), ["fresh"])
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)

        await client.complete(1, items: [.init(id: "cancelled", name: "Cancelled.txt")])
        await first.value
        XCTAssertEqual(store.items.map(\.id), ["fresh"])
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testOlderRootResponseCannotOverwriteANewerFolder() async {
        let suite = "OneDriveBrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OneDriveBrowserStore(defaults: defaults)
        let client = DeferredOneDriveBrowser()
        let root = Task { await store.start(client: client, accountID: "browser-test-drive") }
        _ = await client.waitForRequest(1)
        let folder = OneDriveItem(id: "photos", name: "Photos", isFolder: true)
        let navigation = Task { await store.navigate([folder], client: client) }
        let requested = await client.waitForRequest(2)
        XCTAssertEqual(requested, "photos")
        await client.complete(2, items: [.init(id: "photo", name: "Sample.png")])
        await navigation.value
        await client.complete(1, items: [.init(id: "root-file", name: "Root.txt")])
        await root.value

        XCTAssertEqual(store.path.map(\.id), ["photos"])
        XCTAssertEqual(store.items.map(\.id), ["photo"])
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testSuccessfullyLoadedEmptyFolderIsNotMistakenForAnInterruptedLoad() async {
        let suite = "OneDriveBrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OneDriveBrowserStore(defaults: defaults)
        let client = DeferredOneDriveBrowser()
        let load = Task { await store.start(client: client, accountID: "browser-test-drive") }
        _ = await client.waitForRequest(1)
        await client.complete(1, items: [])
        await load.value
        await store.start(client: client, accountID: "browser-test-drive")
        let count = await client.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testDefaultFolderRestoresUsingItsItemIDAndSeparateAccountPreference() async {
        let suite = "OneDriveBrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = OneDriveBrowserStore(defaults: defaults)
        let client = DeferredOneDriveBrowser()
        let folder = OneDriveItem(id: "saved-folder", name: "照片", isFolder: true)
        let navigation = Task { await original.navigate([folder], client: client) }
        _ = await client.waitForRequest(1)
        await client.complete(1, items: [])
        await navigation.value
        original.saveDefault(accountID: "browser-test-drive")

        let restored = OneDriveBrowserStore(defaults: defaults)
        let restore = Task { await restored.start(client: client, accountID: "browser-test-drive") }
        let restoreID = await client.waitForRequest(2)
        XCTAssertEqual(restoreID, "saved-folder")
        await client.complete(2, items: [])
        await restore.value
        XCTAssertEqual(restored.path.map(\.id), ["saved-folder"])
        XCTAssertEqual(restored.defaultName, "照片")

        let otherAccount = OneDriveBrowserStore(defaults: defaults)
        let other = Task { await otherAccount.start(client: client, accountID: "another-drive") }
        let otherID = await client.waitForRequest(3)
        XCTAssertEqual(otherID, "root")
        await client.complete(3, items: [])
        await other.value
        XCTAssertTrue(otherAccount.path.isEmpty)
        XCTAssertNil(otherAccount.defaultName)
    }
}
