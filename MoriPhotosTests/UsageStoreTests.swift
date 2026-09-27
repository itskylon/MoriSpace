import XCTest
@testable import MoriPhotos

@MainActor final class UsageStoreTests: XCTestCase {
    private var folder: URL!
    private var cache: UsageWidgetCache!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("UsageStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cache = UsageWidgetCache(fileURL: folder.appendingPathComponent(UsageWidgetConstants.fileName))
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func record(fetchedAt: Date? = nil, used: Double? = 28) -> UsageWidgetSnapshot {
        let date = fetchedAt ?? now.addingTimeInterval(-60)
        return UsageWidgetSnapshot(fetchedAt: date, validUntil: date.addingTimeInterval(900), status: .ready, windows: [
            UsageWidgetWindow(id: "codex:primary", label: "Codex · 5 小时", usedPercent: used, windowMinutes: 300,
                              resetsAt: date.addingTimeInterval(3600))
        ])
    }
    private func makeStore(allowsImport: Bool = true, reloadWidgets: @escaping () -> Void = {}) -> UsageStore {
        UsageStore(cache: cache, allowsImport: allowsImport, now: { self.now }, useLocalHelper: false, useRemoteSync: false, reloadWidgets: reloadWidgets)
    }
    private func importedFile(_ data: Data, name: String = "import.json") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func testReloadReadsHelperRecordWithoutRewritingItAndOnlyNotifiesForChanges() throws {
        let source = record()
        try cache.write(source, now: now)
        let originalData = try Data(contentsOf: XCTUnwrap(cache.fileURL))
        var reloads = 0
        let store = makeStore(allowsImport: false, reloadWidgets: { reloads += 1 })
        store.reload(); store.reload()
        XCTAssertEqual(store.snapshot, source)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cache.fileURL)), originalData)
        XCTAssertNil(store.error)
        let updated = record(used: 37)
        try cache.write(updated, now: now)
        store.reload()
        XCTAssertEqual(store.snapshot, updated)
        XCTAssertEqual(reloads, 2)
    }

    func testInvalidCacheRefreshRetainsDisplayedGoodRecordAndDoesNotOverwriteHelperFile() throws {
        let source = record()
        try cache.write(source, now: now)
        let store = makeStore(allowsImport: false)
        store.reload()
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: XCTUnwrap(cache.fileURL))
        store.reload()
        XCTAssertEqual(store.snapshot, source)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cache.fileURL)), corrupt)
    }

    func testImportPreservesExpiredTimestampsAndReplacesSameNamedRecord() async throws {
        let stale = record(fetchedAt: now.addingTimeInterval(-3600))
        let otherFolder = folder.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let input = otherFolder.appendingPathComponent(UsageWidgetConstants.fileName)
        try stale.encoded(now: now).write(to: input)
        var reloads = 0
        let store = makeStore(reloadWidgets: { reloads += 1 })
        await store.importSnapshot(from: input)
        XCTAssertEqual(store.snapshot, stale)
        XCTAssertTrue(store.snapshot.isStale(at: now))
        XCTAssertEqual(cache.read(now: now), stale)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(store.importNotice, "已导入记录，非实时同步。")
        XCTAssertFalse(store.importing)
        // A selected file can also be the cache itself; bytes are read before the atomic replacement.
        await store.importSnapshot(from: try XCTUnwrap(cache.fileURL))
        XCTAssertEqual(cache.read(now: now), stale)
        XCTAssertNil(store.error)
        XCTAssertEqual(reloads, 1)
    }

    func testMalformedFutureVersionAndOutOfRangeImportsLeaveGoodDataUntouched() async throws {
        let source = record()
        try cache.write(source, now: now)
        let expected = try Data(contentsOf: XCTUnwrap(cache.fileURL))
        let store = makeStore()
        store.reload()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        var future = base
        future["fetchedAt"] = now.addingTimeInterval(60).timeIntervalSince1970
        future["validUntil"] = now.addingTimeInterval(960).timeIntervalSince1970
        var version = base; version["version"] = 2
        var excessive = base
        var windows = try XCTUnwrap(excessive["windows"] as? [[String: Any]])
        windows[0]["usedPercent"] = 101
        excessive["windows"] = windows
        var negative = base
        windows[0]["usedPercent"] = -1
        negative["windows"] = windows
        let invalid = [Data("{".utf8), try JSONSerialization.data(withJSONObject: future),
                       try JSONSerialization.data(withJSONObject: version), try JSONSerialization.data(withJSONObject: excessive),
                       try JSONSerialization.data(withJSONObject: negative), Data(repeating: 32, count: UsageWidgetConstants.maximumFileSize + 1)]
        for data in invalid {
            await store.importSnapshot(from: try importedFile(data))
            XCTAssertEqual(store.snapshot, source)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cache.fileURL)), expected)
            XCTAssertNotNil(store.error)
            XCTAssertFalse(store.importing)
        }
    }

    func testMacImportPolicyCannotReplaceHelperRecord() async throws {
        let source = record()
        try cache.write(source, now: now)
        let store = makeStore(allowsImport: false)
        store.reload()
        let replacement = try importedFile(record(used: 99).encoded(now: now))
        await store.importSnapshot(from: replacement)
        XCTAssertEqual(store.snapshot, source)
        XCTAssertEqual(cache.read(now: now), source)
        XCTAssertNotNil(store.error)
    }

    func testExportWhitelistsSnapshotAndDoesNotRefreshCollectorDates() async throws {
        let source = record()
        var extended = try XCTUnwrap(JSONSerialization.jsonObject(with: source.encoded(now: now)) as? [String: Any])
        extended["unrelatedMetadata"] = "must-not-be-exported"
        let input = try importedFile(JSONSerialization.data(withJSONObject: extended))
        let store = makeStore()
        await store.importSnapshot(from: input)
        let output = try store.exportData()
        let decoded = try UsageWidgetSnapshot.decode(output, now: now)
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.fetchedAt, source.fetchedAt)
        XCTAssertEqual(decoded.validUntil, source.validUntil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertNil(object["unrelatedMetadata"])
        XCTAssertEqual(Set(object.keys), ["version", "fetchedAt", "validUntil", "status", "windows"])
    }

    func testUnavailableSharedContainerRejectsImportWithoutDiscardingDisplayedData() async throws {
        let source = record()
        let input = try importedFile(source.encoded(now: now))
        let store = UsageStore(cache: UsageWidgetCache(fileURL: nil), allowsImport: true, now: { self.now }, useLocalHelper: false, useRemoteSync: false, reloadWidgets: {})
        let original = store.snapshot
        await store.importSnapshot(from: input)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.importing)
    }

    func testReplacedImportPathCannotReuseCachedRegularFileMetadata() async throws {
        let source = record()
        try cache.write(source, now: now)
        let store = makeStore(); store.reload()
        let input = try importedFile(record(used: 99).encoded(now: now))
        _ = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        try FileManager.default.removeItem(at: input)
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: XCTUnwrap(cache.fileURL))
        await store.importSnapshot(from: input)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.snapshot, source)
        XCTAssertEqual(cache.read(now: now), source)
    }
    func testLocalHelperSuccessWritesValidatedRecordWithoutChangingCollectorTimes() async throws {
        let source = record()
        var widgetReloads = 0
        let store = UsageStore(cache: cache, allowsImport: false, now: { self.now }, useLocalHelper: false, useRemoteSync: false,
                               localReader: { source }, reloadWidgets: { widgetReloads += 1 })
        store.reload()
        await waitUntilIdle(store)
        XCTAssertEqual(store.snapshot, source)
        XCTAssertEqual(cache.read(now: now), source)
        XCTAssertEqual(widgetReloads, 1)
        XCTAssertNil(store.error)
        store.reload()
        await waitUntilIdle(store)
        XCTAssertEqual(widgetReloads, 1)
        XCTAssertEqual(store.snapshot.fetchedAt, source.fetchedAt)
    }

    func testLocalHelperFailurePreservesCachedBytesAndCollectorTimes() async throws {
        let source = record()
        try cache.write(source, now: now)
        let originalBytes = try Data(contentsOf: XCTUnwrap(cache.fileURL))
        let store = UsageStore(cache: cache, allowsImport: false, now: { self.now }, useLocalHelper: false, useRemoteSync: false,
                               localReader: { throw URLError(.cannotConnectToHost) }, reloadWidgets: {})
        store.reload()
        await waitUntilIdle(store)
        XCTAssertEqual(store.snapshot, source)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cache.fileURL)), originalBytes)
        XCTAssertNotNil(store.error)
    }

    func testUnavailableLocalRecordAndInvalidFutureRecordDoNotReplaceGoodCache() async throws {
        let source = record()
        try cache.write(source, now: now)
        for next in [UsageWidgetSnapshot.empty(.unavailable, now: now), record(fetchedAt: now.addingTimeInterval(60))] {
            let store = UsageStore(cache: cache, allowsImport: false, now: { self.now }, useLocalHelper: false, useRemoteSync: false,
                                   localReader: { next }, reloadWidgets: {})
            store.reload()
            await waitUntilIdle(store)
            XCTAssertEqual(store.snapshot, source)
            XCTAssertEqual(cache.read(now: now), source)
            XCTAssertNotNil(store.error)
        }
    }

    func testSupersededAndCancelledLocalResponsesCannotOverwriteLatestRecord() async throws {
        let reader = DeferredUsageReader()
        let store = UsageStore(cache: cache, allowsImport: false, now: { self.now }, useLocalHelper: false, useRemoteSync: false,
                               localReader: { try await reader.read() }, reloadWidgets: {})
        store.reload()
        await reader.waitForRequests(1)
        store.reload()
        await reader.waitForRequests(2)
        let newest = record(fetchedAt: now.addingTimeInterval(-5), used: 61)
        reader.resolve(1, with: newest)
        await waitUntilIdle(store)
        reader.resolve(0, with: record(used: 10))
        await reader.waitForCompletions(2)
        await Task.yield()
        XCTAssertEqual(store.snapshot, newest)
        XCTAssertEqual(cache.read(now: now), newest)
        store.reload()
        await reader.waitForRequests(3)
        store.cancelRefresh()
        reader.resolve(2, with: record(fetchedAt: now, used: 75))
        await reader.waitForCompletions(3)
        await Task.yield()
        XCTAssertFalse(store.refreshing)
        XCTAssertEqual(store.snapshot, newest)
        XCTAssertEqual(cache.read(now: now), newest)
        XCTAssertNil(store.error)
    }

    func testSharedCacheRejectsOlderWritesAndAcceptsEqualCollectionTime() throws {
        let recent = record(fetchedAt: now.addingTimeInterval(-5), used: 61)
        try cache.write(recent, now: now)
        let staleWriterResult = try cache.write(record(used: 10), now: now)
        XCTAssertEqual(staleWriterResult, recent)
        XCTAssertEqual(cache.read(now: now), recent)
        let sameTime = record(fetchedAt: recent.fetchedAt, used: 62)
        XCTAssertEqual(try cache.write(sameTime, now: now), sameTime)
        XCTAssertEqual(cache.read(now: now), sameTime)
    }

    func testStoreRejectsCacheRollbackAndRetainsNewerSnapshotFromConcurrentWriter() async throws {
        let recent = record(fetchedAt: now.addingTimeInterval(-5), used: 61)
        try cache.write(recent, now: now)
        let store = makeStore(); store.reload()
        // Simulate an older app version replacing the file without the shared write guard.
        try record(used: 10).encoded(now: now).write(to: XCTUnwrap(cache.fileURL), options: .atomic)
        store.reload()
        XCTAssertEqual(store.snapshot, recent)

        let reader = DeferredUsageReader()
        let concurrent = UsageStore(cache: cache, allowsImport: false, now: { self.now }, useLocalHelper: false, useRemoteSync: false,
                                    localReader: { try await reader.read() }, reloadWidgets: {})
        concurrent.reload()
        await reader.waitForRequests(1)
        // The widget wins the race while the app still awaits an earlier helper response.
        let latest = record(fetchedAt: now.addingTimeInterval(-1), used: 77)
        try cache.write(latest, now: now)
        reader.resolve(0, with: record(fetchedAt: now.addingTimeInterval(-10), used: 33))
        await waitUntilIdle(concurrent)
        XCTAssertEqual(cache.read(now: now), latest)
        XCTAssertEqual(concurrent.snapshot, latest)
    }

    func testRemoteSwitchSurvivesLifecyclePollingCancellationAndAcceptsDifferentSourcesOlderTimestamp() async throws {
        let previous = try remoteConfiguration("old")
        let next = try remoteConfiguration("next")
        let probe = UsageConfigurationProbe(previous)
        let reader = DeferredUsageReader()
        let oldRecord = record(fetchedAt: now.addingTimeInterval(-5), used: 12)
        let nextRecord = record(fetchedAt: now.addingTimeInterval(-60), used: 87)
        try cache.write(oldRecord, now: now)
        let store = remoteStore(probe: probe) { configuration in
            if configuration == previous { return oldRecord }
            return try await reader.read()
        }
        store.reload(); await waitUntilIdle(store)
        let input = try importedFile(next.encoded())
        let connection = Task { await store.connectRemote(from: input) }
        await reader.waitForRequests(1)
        XCTAssertTrue(store.importing)
        store.cancelRefresh() // Sheet presentation / inactive scene stops polling only.
        store.reload() // Scene activation and the foreground timer must not cancel provisioning.
        reader.resolve(0, with: nextRecord)
        let connected = await connection.value
        XCTAssertTrue(connected)
        XCTAssertEqual(probe.value, next)
        XCTAssertEqual(store.remoteConfiguration, next)
        XCTAssertEqual(store.snapshot, nextRecord)
        XCTAssertEqual(cache.read(now: now), nextRecord)
        XCTAssertNil(store.error)
    }

    func testFailedRemoteSaveRestoresOriginalCredentialAndQuota() async throws {
        let previous = try remoteConfiguration("old")
        let next = try remoteConfiguration("next")
        let probe = UsageConfigurationProbe(previous)
        probe.rejectedSave = next
        let original = record(used: 12)
        try cache.write(original, now: now)
        let store = remoteStore(probe: probe) { configuration in
            configuration == previous ? original : self.record(used: 87)
        }
        store.reload(); await waitUntilIdle(store)
        let connected = await store.connectRemote(from: try importedFile(next.encoded()))
        XCTAssertFalse(connected)
        XCTAssertEqual(probe.value, previous)
        XCTAssertEqual(store.remoteConfiguration, previous)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(cache.read(now: now), original)
        XCTAssertNotNil(store.error)
    }

    func testFailedRemoteDeleteRestoresQuotaAndConnectedState() async throws {
        let configuration = try remoteConfiguration("old")
        let probe = UsageConfigurationProbe(configuration)
        probe.rejectDelete = true
        let original = record()
        try cache.write(original, now: now)
        let store = remoteStore(probe: probe) { _ in original }
        store.reload(); await waitUntilIdle(store)
        store.disconnectRemote()
        XCTAssertEqual(probe.value, configuration)
        XCTAssertTrue(store.syncEnabled)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(cache.read(now: now), original)
        XCTAssertNotNil(store.error)
    }

    func testLateRemoteRefreshCannotRecreateCacheAfterDisconnect() async throws {
        let probe = UsageConfigurationProbe(try remoteConfiguration("old"))
        let reader = DeferredUsageReader()
        try cache.write(record(), now: now)
        let store = remoteStore(probe: probe) { _ in try await reader.read() }
        store.reload(); await reader.waitForRequests(1)
        store.disconnectRemote()
        reader.resolve(0, with: record(fetchedAt: now, used: 99))
        await reader.waitForCompletions(1)
        await Task.yield()
        XCTAssertNil(probe.value)
        XCTAssertFalse(store.syncEnabled)
        XCTAssertEqual(store.snapshot.status, .notConnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(cache.fileURL).path))
        XCTAssertNil(store.error)
    }

    func testPendingConnectionPreservesDisconnectedAndReplacedFilesAndDeletesOnlyConsumedFile() async throws {
        let previous = try remoteConfiguration("old")
        let next = try remoteConfiguration("next")
        let later = try remoteConfiguration("later")
        let probe = UsageConfigurationProbe(previous)
        let reader = DeferredUsageReader()
        let input = try importedFile(next.encoded(), name: "connection.json")
        let store = remoteStore(probe: probe, pending: input) { _ in try await reader.read() }
        let cancelled = Task { await store.connectPendingRemote() }
        await reader.waitForRequests(1)
        store.disconnectRemote()
        reader.resolve(0, with: record())
        await cancelled.value
        XCTAssertEqual(try Data(contentsOf: input), try next.encoded())
        XCTAssertNil(probe.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(cache.fileURL).path))

        let replaced = Task { await store.connectPendingRemote() }
        await reader.waitForRequests(2)
        try later.encoded().write(to: input, options: .atomic)
        reader.resolve(1, with: record(used: 65))
        await replaced.value
        XCTAssertEqual(probe.value, next)
        XCTAssertEqual(try Data(contentsOf: input), try later.encoded())

        let consumed = Task { await store.connectPendingRemote() }
        await reader.waitForRequests(3)
        reader.resolve(2, with: record(used: 66))
        await consumed.value
        XCTAssertEqual(probe.value, later)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertNil(store.error)
    }

    func testConnectionErrorPersistsAcrossCacheReloadsAndClearsOnlyOnSuccessfulRetry() async throws {
        let configuration = try remoteConfiguration("next")
        let probe = UsageConfigurationProbe(nil)
        let original = record()
        var shouldFail = true
        let store = remoteStore(probe: probe) { _ in
            if shouldFail { throw URLError(.secureConnectionFailed, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://must-not-be-shown.invalid/secret"]) }
            return original
        }
        let input = try importedFile(configuration.encoded())
        let connected = await store.connectRemote(from: input)
        XCTAssertFalse(connected)
        let message = try XCTUnwrap(store.error)
        XCTAssertTrue(message.contains("HTTPS"))
        XCTAssertTrue(message.contains("-1200"))
        XCTAssertFalse(message.contains("must-not-be-shown"))
        store.cancelRefresh(); store.reload()
        XCTAssertEqual(store.error, message)
        try cache.write(original, now: now)
        store.reload()
        XCTAssertEqual(store.error, message)
        shouldFail = false
        let retry = await store.connectRemote(from: input)
        XCTAssertTrue(retry)
        XCTAssertNil(store.error)
    }

    func testFailedSourceSwitchErrorSurvivesSuccessfulRefreshOfOriginalSource() async throws {
        let previous = try remoteConfiguration("old")
        let next = try remoteConfiguration("next")
        let probe = UsageConfigurationProbe(previous)
        probe.rejectedSave = next
        let original = record()
        let store = remoteStore(probe: probe) { _ in original }
        let connected = await store.connectRemote(from: try importedFile(next.encoded()))
        XCTAssertFalse(connected)
        let message = try XCTUnwrap(store.error)
        store.reload(); await waitUntilIdle(store)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.error, message)
        XCTAssertEqual(probe.value, previous)
    }

    func testMissingPendingFileReportsActionableErrorOrExistingConnection() async throws {
        let missing = folder.appendingPathComponent("missing-connection.json")
        let probe = UsageConfigurationProbe(nil)
        let source = record()
        let store = remoteStore(probe: probe, pending: missing) { _ in source }
        XCTAssertFalse(store.hasPendingRemoteConfiguration)
        await store.connectPendingRemote()
        let message = try XCTUnwrap(store.error)
        XCTAssertTrue(message.contains("没有找到连接文件"))
        store.reload()
        XCTAssertEqual(store.error, message)

        probe.value = try remoteConfiguration("existing")
        let connected = remoteStore(probe: probe, pending: missing) { _ in source }
        await connected.connectPendingRemote()
        await waitUntilIdle(connected)
        XCTAssertTrue(connected.syncEnabled)
        XCTAssertTrue(connected.importNotice?.contains("已连接") == true)
        XCTAssertNil(connected.error)
        XCTAssertEqual(connected.snapshot, source)
    }

    func testOfflineImportCannotReplaceAnEnabledRemoteSource() async throws {
        let probe = UsageConfigurationProbe(try remoteConfiguration("old"))
        let original = record()
        try cache.write(original, now: now)
        let store = remoteStore(probe: probe) { _ in original }
        store.reload(); await waitUntilIdle(store)
        await store.importSnapshot(from: try importedFile(record(fetchedAt: now, used: 99).encoded(now: now)))
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(cache.read(now: now), original)
        XCTAssertTrue(store.syncEnabled)
        XCTAssertNotNil(store.error)
    }

    private func remoteConfiguration(_ path: String) throws -> UsageRemoteConfiguration {
        try UsageRemoteConfiguration(baseURL: "https://example.invalid/" + path, readToken: String(repeating: "ab", count: 32))
    }

    private func remoteStore(probe: UsageConfigurationProbe, pending: URL? = nil,
                             fetch: @escaping (UsageRemoteConfiguration) async throws -> UsageWidgetSnapshot) -> UsageStore {
        UsageStore(cache: cache, allowsImport: true, now: { self.now }, useLocalHelper: false, useRemoteSync: true,
                   configurationLoad: { probe.value }, configurationSave: { try probe.save($0) },
                   configurationDelete: { try probe.delete() }, remoteFetch: fetch,
                   pendingConfigurationURL: pending, reloadWidgets: {})
    }

    private func waitUntilIdle(_ store: UsageStore) async {
        for _ in 0..<1_000 {
            if !store.refreshing { return }
            await Task.yield()
        }
        XCTFail("Local reader did not finish")
    }

}

@MainActor private final class UsageConfigurationProbe {
    var value: UsageRemoteConfiguration?
    var rejectedSave: UsageRemoteConfiguration?
    var rejectDelete = false
    init(_ value: UsageRemoteConfiguration?) { self.value = value }
    func save(_ configuration: UsageRemoteConfiguration) throws {
        if configuration == rejectedSave { throw CocoaError(.fileWriteUnknown) }
        value = configuration
    }
    func delete() throws {
        if rejectDelete { throw CocoaError(.fileWriteUnknown) }
        value = nil
    }
}


@MainActor private final class DeferredUsageReader {
    private var requests: [CheckedContinuation<UsageWidgetSnapshot, Error>] = []
    private var completions = 0
    func read() async throws -> UsageWidgetSnapshot {
        defer { completions += 1 }
        return try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func resolve(_ index: Int, with snapshot: UsageWidgetSnapshot) { requests[index].resume(returning: snapshot) }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<1_000 {
            if requests.count >= count { return }
            await Task.yield()
        }
        XCTFail("Local reader request did not arrive")
    }
    func waitForCompletions(_ count: Int) async {
        for _ in 0..<1_000 {
            if completions >= count { return }
            await Task.yield()
        }
        XCTFail("Local reader response did not complete")
    }
}
