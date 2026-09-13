#if targetEnvironment(simulator)
import XCTest
import AVFoundation
@testable import MoriPhotos

final class VideoPlaybackTests: XCTestCase {
    private func client() async throws -> SynologyClient {
        let client = try SynologyClient(address: FileStationFixture.credentials.address, service: .files, session: URLSession(configuration: FileStationFixture.configuration()))
        try await client.login(FileStationFixture.credentials, otp: "")
        return client
    }
    private func fixture() throws -> Data {
        let data = FileStationFixture.videoData
        guard data.count > 1_048_576 else { throw XCTSkip("Run Scripts/PrepareVideoTests.command on the QA simulator first") }
        return data
    }
    func testRangeValidationRejectsWrongOffsetsTruncationAndOverflow() throws {
        XCTAssertEqual(try VideoContentRange.parse("bytes 10-19/100", requestedStart: 10, requestedEnd: 19).count, 10)
        XCTAssertEqual(try VideoContentRange.parse("bytes 90-99/100", requestedStart: 90, requestedEnd: 120).count, 10)
        for header in [nil, "bytes 0-19/100", "bytes 10-18/100", "bytes 10-20/100", "bytes 10-19/*", "bytes 10-19/19", "bytes 10-19/9999999999999999999999"] {
            XCTAssertThrowsError(try VideoContentRange.parse(header, requestedStart: 10, requestedEnd: 19))
        }
    }
    func testAuthenticatedRangesAndSeekReadOnlyRequestedWindow() async throws {
        let fixture = try fixture(), client = try await client()
        let request = try await client.videoRequest(path: "/测试共享/测试视频.mp4")
        let special = try await client.videoRequest(path: "/测试共享/a + b&c%.mp4")
        XCTAssertTrue(special.url!.absoluteString.contains("%2B"))
        XCTAssertFalse(special.url!.absoluteString.contains("+"))
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        let names = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)
        XCTAssertFalse(names.contains("_sid")); XCTAssertFalse(names.contains("SynoToken")); XCTAssertFalse(names.contains("passwd"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=file-test-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "file-test-token")
        let source = VideoByteSource(request: request, filename: "测试视频.mp4", expectedSize: Int64(fixture.count), configuration: FileStationFixture.configuration())
        let info = try await source.metadata()
        XCTAssertEqual(info.length, Int64(fixture.count))
        let start = 1_048_576 + 137
        let data = try await source.read(offset: Int64(start), length: 73)
        XCTAssertEqual(data, fixture.subdata(in: start..<(start + 73)))
        let firstCount = await source.bytesReceived
        XCTAssertLessThan(firstCount, Int64(fixture.count))
        _ = try await source.read(offset: Int64(start + 1), length: 30)
        let secondCount = await source.bytesReceived
        XCTAssertEqual(firstCount, secondCount, "Nearby reads reuse the bounded cache")
        await source.stop()
        do { _ = try await source.read(offset: 0, length: 1); XCTFail("Stopped source must reject reads") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMissingRangeSupportAndExpiredSessionAreExplicitErrors() async throws {
        let fixture = try fixture(), client = try await client()
        let request = try await client.videoRequest(path: "/测试共享/无分段.mp4")
        let source = VideoByteSource(request: request, filename: "无分段.mp4", expectedSize: Int64(fixture.count), configuration: FileStationFixture.configuration())
        do { _ = try await source.metadata(); XCTFail("Expected unsupported range") }
        catch { XCTAssertTrue(error.localizedDescription.contains("先下载")) }
        await source.stop()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responder = { _ in (200, Data("{\"success\":false,\"error\":{\"code\":119}}".utf8)) }
        defer { MockURLProtocol.responder = nil }
        let expired = VideoByteSource(request: request, filename: "video.mp4", expectedSize: nil, configuration: config)
        do { _ = try await expired.metadata(); XCTFail("Expected session error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("119")); XCTAssertTrue(error.localizedDescription.contains("重新连接")) }
        await expired.stop()
    }
    @MainActor
    func testRemoteVideoDecodesFramesPlaysPausesAndSeeks() async throws {
        _ = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await client(), model = VideoPlaybackModel(progressStore: VideoProgressStore(directory: directory))
        defer { model.stop() }
        let file = try await client.fileInfo(path: "/测试共享/测试视频.mp4")
        await model.open(file: file, owner: "test-owner", client: client, localURL: nil, configuration: FileStationFixture.configuration())
        XCTAssertNil(model.error)
        XCTAssertGreaterThan(model.duration, 30)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem?.add(output)
        await wait { model.elapsed > 1 || model.error != nil }
        XCTAssertNil(model.error)
        var hasFrame = false
        await wait {
            hasFrame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) != nil
            return hasFrame
        }
        XCTAssertTrue(hasFrame, "Playback must decode a real video frame")
        model.jump(15)
        await wait { model.elapsed >= 15 }
        model.toggle()
        await wait { !model.playing }
        let paused = model.elapsed
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.elapsed, paused, accuracy: 0.5)
        model.stop()
        XCTAssertNil(model.player.currentItem)
    }
    @MainActor
    func testDownloadedVideoPlaysWithoutNASConnection() async throws {
        _ = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = VideoPlaybackModel(progressStore: VideoProgressStore(directory: directory))
        defer { model.stop() }
        let file = NASFile(name: "已下载.mp4", path: "/测试共享/已下载.mp4", isdir: false, additional: nil)
        await model.open(file: file, owner: "test-owner", client: nil, localURL: FileStationFixture.videoURL)
        XCTAssertNil(model.error)
        await wait { model.elapsed > 0.5 }
        XCTAssertGreaterThan(model.elapsed, 0.5)
    }
    @MainActor
    func testOnlineProgressResumesOfflineAfterRecreationAndRestartClearsIt() async throws {
        _ = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await client(), store = VideoProgressStore(directory: directory)
        let file = try await client.fileInfo(path: "/测试共享/测试视频.mp4")
        let key = VideoProgressStore.key(owner: "same-owner", file: file)
        let online = VideoPlaybackModel(progressStore: store)
        defer { online.stop() }
        await online.open(file: file, owner: "same-owner", client: client, localURL: nil, configuration: FileStationFixture.configuration())
        XCTAssertNil(online.error)
        await wait { online.elapsed > 1 }
        online.jump(15)
        await wait { (store.position(for: key, duration: online.duration) ?? 0) >= 15 }
        online.pause()
        let stoppedAt = online.player.currentTime().seconds
        online.stop(); online.stop()

        let offlineStore = VideoProgressStore(directory: directory)
        let offline = VideoPlaybackModel(progressStore: offlineStore)
        defer { offline.stop() }
        await offline.open(file: file, owner: "same-owner", client: nil, localURL: FileStationFixture.videoURL)
        XCTAssertNil(offline.error)
        XCTAssertEqual(offline.resumedFrom ?? 0, stoppedAt, accuracy: 0.5)
        XCTAssertEqual(offline.player.currentTime().seconds, stoppedAt, accuracy: 1)
        offline.restart()
        await wait { offline.resumedFrom == nil && offline.elapsed < 2 }
        offline.pause(); offline.stop()
        XCTAssertNil(VideoProgressStore(directory: directory).position(for: key, duration: online.duration))
    }
    @MainActor
    func testFailedOpenDoesNotOverwriteSavedPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = NASFile(name: "missing.mp4", path: "/videos/missing.mp4", isdir: false, additional: nil)
        let store = VideoProgressStore(directory: directory), key = VideoProgressStore.key(owner: "test", file: file)
        try store.save(key: key, position: 20, duration: 40)
        let model = VideoPlaybackModel(progressStore: store)
        await model.open(file: file, owner: "test", client: nil, localURL: directory.appendingPathComponent("missing.mp4"))
        XCTAssertNotNil(model.error)
        model.stop()
        XCTAssertEqual(VideoProgressStore(directory: directory).position(for: key, duration: 40), 20)
    }
    @MainActor private func wait(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Timed out waiting for video playback")
    }
}
#endif
