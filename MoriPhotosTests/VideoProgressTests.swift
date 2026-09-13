import XCTest
@testable import MoriPhotos

@MainActor
final class VideoProgressTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func file(path: String = "/videos/a.mp4", size: Int64 = 100, modified: Double = 1000) -> NASFile {
        NASFile(name: "a.mp4", path: path, isdir: false, additional: .init(size: size, time: .init(mtime: modified)))
    }
    func testProgressSurvivesStoreRecreationAndAccountFileChangesAreIsolated() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoProgressStore(directory: directory)
        let key = VideoProgressStore.key(owner: "account-a", file: file())
        try store.save(key: key, position: 137, duration: 500)
        let reopened = VideoProgressStore(directory: directory)
        XCTAssertEqual(reopened.position(for: key, duration: 500), 137)
        for other in [VideoProgressStore.key(owner: "account-b", file: file()),
                      VideoProgressStore.key(owner: "account-a", file: file(path: "/else/a.mp4")),
                      VideoProgressStore.key(owner: "account-a", file: file(size: 101)),
                      VideoProgressStore.key(owner: "account-a", file: file(modified: 1001))] {
            XCTAssertNil(reopened.position(for: other, duration: 500))
        }
        XCTAssertNil(reopened.position(for: key, duration: 600))
        let json = try String(contentsOf: directory.appendingPathComponent("progress.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("/videos/")); XCTAssertFalse(json.contains("account-a"))
    }
    func testFinishedAndRestartedVideosBeginAtZero() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoProgressStore(directory: directory)
        try store.save(key: "a", position: 15, duration: 40)
        XCTAssertEqual(store.position(for: "a", duration: 40), 15)
        try store.save(key: "a", position: 39.5, duration: 40)
        XCTAssertNil(VideoProgressStore(directory: directory).position(for: "a", duration: 40))
        try store.save(key: "a", position: 15, duration: 40)
        try store.save(key: "a", position: 0, duration: 40)
        XCTAssertNil(VideoProgressStore(directory: directory).position(for: "a", duration: 40))
    }
    func testInvalidPlayerTimesDoNotDestroyExistingProgress() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoProgressStore(directory: directory)
        try store.save(key: "a", position: 15, duration: 40)
        for value in [Double.nan, .infinity, -1] { try store.save(key: "a", position: value, duration: 40) }
        try store.save(key: "a", position: 0, duration: 0)
        XCTAssertEqual(VideoProgressStore(directory: directory).position(for: "a", duration: 40), 15)
    }
    func testWriteFailureCanBeRetriedWithoutLosingPreviousEntry() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoProgressStore(directory: directory)
        try store.save(key: "a", position: 15, duration: 40)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        XCTAssertThrowsError(try store.remove(key: "a"))
        XCTAssertEqual(store.position(for: "a", duration: 40), 15)
        try FileManager.default.removeItem(at: directory)
        try store.remove(key: "a")
        XCTAssertNil(VideoProgressStore(directory: directory).position(for: "a", duration: 40))
    }
}
