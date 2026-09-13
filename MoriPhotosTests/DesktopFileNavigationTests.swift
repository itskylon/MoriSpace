import XCTest
@testable import MoriPhotos

@MainActor
final class DesktopFileNavigationTests: XCTestCase {
    private func folder(_ path: String) -> NASFile { NASFile(name: (path as NSString).lastPathComponent, path: path, isdir: true, additional: nil) }
    func testHistoryAndBreadcrumbsReturnToExactSpecialCharacterPaths() {
        let navigation = DesktopFileNavigation()
        navigation.goBack(); navigation.goForward(); navigation.goUp()
        XCTAssertNil(navigation.current.folder)
        navigation.open(folder("/共享")); navigation.open(folder("/共享/中文 + & #%.files"))
        XCTAssertEqual(navigation.breadcrumbs.map(\.path), ["/共享", "/共享/中文 + & #%.files"])
        navigation.goBack(); XCTAssertEqual(navigation.current.key, "/共享")
        navigation.goForward(); XCTAssertEqual(navigation.current.key, "/共享/中文 + & #%.files")
        navigation.goUp(); XCTAssertEqual(navigation.current.key, "/共享")
        navigation.goUp(); XCTAssertNil(navigation.current.folder)
        XCTAssertFalse(navigation.canGoUp)
    }
    func testBackRestoresQuerySelectionSortAndLoadedItems() {
        let navigation = DesktopFileNavigation()
        navigation.open(folder("/共享"))
        let saved = navigation.current
        saved.query = "中文"; saved.selection = "/共享/中文.txt"; saved.sort = .size; saved.ascending = false
        saved.store.items = [folder("/共享/子目录")]
        navigation.open(folder("/共享/子目录")); navigation.goBack()
        XCTAssertTrue(navigation.current === saved)
        XCTAssertEqual(navigation.current.query, "中文"); XCTAssertEqual(navigation.current.selection, "/共享/中文.txt")
        XCTAssertEqual(navigation.current.sort, .size); XCTAssertFalse(navigation.current.ascending)
        XCTAssertEqual(navigation.current.store.items.count, 1)
    }
    func testOpeningNewBranchClearsForwardAndFilesNeverBecomeDirectories() {
        let navigation = DesktopFileNavigation()
        navigation.open(folder("/a")); navigation.open(folder("/a/b")); navigation.goBack()
        navigation.open(folder("/a/c")); XCTAssertTrue(navigation.forward.isEmpty)
        let previous = navigation.current
        navigation.open(NASFile(name: "test.txt", path: "/a/c/test.txt", isdir: false, additional: nil))
        navigation.open(folder("/a/c"))
        XCTAssertTrue(navigation.current === previous); XCTAssertEqual(navigation.back.count, 2)
    }
}

#if targetEnvironment(simulator)
@MainActor
final class NASQuickPreviewTests: XCTestCase {
    private func client() async throws -> SynologyClient {
        let client = try SynologyClient(address: FileStationFixture.credentials.address, service: .files, session: URLSession(configuration: FileStationFixture.configuration()))
        try await client.login(FileStationFixture.credentials, otp: "")
        return client
    }
    func testPreviewPreservesBytesAndFilenameAndRemovesTemporaryFileOnClose() async throws {
        let client = try await client()
        let file = try await client.fileInfo(path: "/测试共享/说明 + 中文.txt")
        let model = NASFilePreviewModel()
        await model.load(file: file, client: client, configuration: FileStationFixture.configuration())
        XCTAssertNil(model.error)
        let url = try XCTUnwrap(model.url)
        XCTAssertEqual(try Data(contentsOf: url), FileStationFixture.contents)
        XCTAssertEqual(url.lastPathComponent, "说明 + 中文.txt")
        model.stop()
        XCTAssertNil(model.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
    func testBoundedTransferRejectsOversizeButRegularDownloadStillWorks() async throws {
        let client = try await client()
        let request = try await client.fileDownloadRequest(path: "/测试共享/test.txt")
        do {
            let (url, _) = try await FileTransfer(configuration: FileStationFixture.configuration(), byteLimit: 10) { _, _ in }.run(request)
            try? FileManager.default.removeItem(at: url)
            XCTFail("Preview transfer must enforce a byte limit")
        } catch { XCTAssertTrue(error is FilePreviewError, error.localizedDescription) }
        let (url, response) = try await FileTransfer(configuration: FileStationFixture.configuration()) { _, _ in }.run(request)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileTransfer.validate(file: url, response: response, expected: Int64(FileStationFixture.contents.count))
        XCTAssertEqual(try Data(contentsOf: url), FileStationFixture.contents)
    }
    func testUnsupportedFilesDoNotPublishAPreview() async throws {
        let client = try await client()
        let file = NASFile(name: "installer.pkg", path: "/测试共享/installer.pkg", isdir: false, additional: nil)
        let model = NASFilePreviewModel()
        await model.load(file: file, client: client, configuration: FileStationFixture.configuration())
        XCTAssertNil(model.url); XCTAssertTrue(model.error?.contains("不支持") == true)
        model.stop()
    }
}
#endif
