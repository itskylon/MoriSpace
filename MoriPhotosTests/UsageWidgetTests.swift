import XCTest
import SwiftUI
@testable import MoriPhotos

final class UsageWidgetDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func payload(_ bucket: [String: Any]) throws -> UsageWidgetSnapshot {
        try UsageWidgetSnapshot.parseRateLimits(data(["rateLimits": bucket]), fetchedAt: now, now: now)
    }
    private func window(_ used: Any = 25, minutes: Any = 180, reset: Any = 1_790_000_600) -> [String: Any] {
        ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": reset]
    }
    private func snapshot(_ used: Double? = 25, reset: Date? = nil) -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(fetchedAt: now, validUntil: now.addingTimeInterval(900), status: .ready, windows: [
            UsageWidgetWindow(id: "codex:primary", label: "Codex · 3 小时", usedPercent: used, windowMinutes: 180, resetsAt: reset)
        ])
    }

    func testMultipleBucketsOverrideLegacyAndOrderCodexFirst() throws {
        let object: [String: Any] = ["result": [
            "rateLimits": ["limitId": "legacy", "primary": window("obsolete-invalid-value")],
            "rateLimitsByLimitId": [
                "other": ["limitName": "另一个额度", "secondary": window(40, minutes: 2880)],
                "codex": ["primary": window(20, minutes: 45), "secondary": NSNull()]
            ]
        ]]
        let result = try UsageWidgetSnapshot.parseRateLimits(data(object), fetchedAt: now, now: now)
        XCTAssertEqual(result.windows.map(\.id), ["codex:primary", "other:secondary"])
        XCTAssertEqual(result.windows.map(\.label), ["Codex · 45 分钟", "另一个额度 · 2 天"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [80, 60])
    }

    func testLegacyFallbackWithMissingNullOrEmptyMultipleBuckets() throws {
        for map: Any? in [nil, NSNull(), [:] as [String: Any]] {
            var object: [String: Any] = ["rateLimits": ["limitId": "codex", "primary": window()]]
            if let map { object["rateLimitsByLimitId"] = map }
            let result = try UsageWidgetSnapshot.parseRateLimits(data(object), fetchedAt: now, now: now)
            XCTAssertEqual(result.windows.count, 1)
            XCTAssertEqual(result.windows.first?.remainingPercent, 75)
            XCTAssertEqual(result.windows.first?.label, "Codex · 3 小时")
        }
    }

    func testNullSecondaryDoesNotInventWeeklyAllowance() throws {
        let result = try payload(["primary": window(31, minutes: 10080), "secondary": NSNull()])
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.label, "Codex · 7 天")
        XCTAssertEqual(result.windows.first?.remainingPercent, 69)
    }

    func testUnknownFieldsRemainMissingInsteadOfZero() throws {
        let result = try payload(["primary": window(NSNull(), minutes: NSNull(), reset: NSNull())])
        let first = try XCTUnwrap(result.windows.first)
        XCTAssertNil(first.usedPercent); XCTAssertNil(first.remainingPercent)
        XCTAssertNil(first.windowMinutes); XCTAssertNil(first.resetsAt)
        XCTAssertEqual(first.label, "Codex · 主额度")
        XCTAssertTrue(try payload(["primary": NSNull(), "secondary": NSNull()]).windows.isEmpty)
        let nullMap = try UsageWidgetSnapshot.parseRateLimits(data([
            "rateLimitsByLimitId": ["codex": NSNull()], "rateLimits": ["primary": window(0)]
        ]), fetchedAt: now, now: now)
        XCTAssertTrue(nullMap.windows.isEmpty, "An explicitly unknown multibucket view must not become legacy 100%")
    }

    func testInvalidPercentageDurationAndRPCErrorAreRejected() throws {
        for value: Any in [-1, 100.01, true, "30"] { XCTAssertThrowsError(try payload(["primary": window(value)])) }
        for minutes in [0, -3] { XCTAssertThrowsError(try payload(["primary": window(25, minutes: minutes)])) }
        XCTAssertThrowsError(try snapshot(.infinity).validated(now: now))
        XCTAssertThrowsError(try snapshot(.nan).validated(now: now))
        XCTAssertThrowsError(try UsageWidgetSnapshot.parseRateLimits(data(["error": ["code": -1]]), fetchedAt: now, now: now))
        XCTAssertThrowsError(try UsageWidgetSnapshot.parseRateLimits(data([:]), fetchedAt: now, now: now))
    }

    func testUnixSecondsRoundTripAndNoCredentialFieldsAreRetained() throws {
        let value = try UsageWidgetSnapshot.parseRateLimits(data([
            "rateLimits": ["primary": window()], "account": ["email": "fixture@example.invalid"], "accessToken": "synthetic-ignored-value"
        ]), fetchedAt: now, now: now)
        let encoded = try value.encoded(now: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["fetchedAt"] as? Double, now.timeIntervalSince1970)
        XCTAssertEqual(Set(json.keys), Set(["version", "fetchedAt", "validUntil", "status", "windows"]))
        XCTAssertNil(json["account"]); XCTAssertNil(json["accessToken"])
        XCTAssertEqual(try UsageWidgetSnapshot.decode(encoded, now: now), value)
    }

    func testFutureAndInvalidValidityWindowsAreRejected() throws {
        let future = UsageWidgetSnapshot.empty(.notConnected, now: now.addingTimeInterval(1))
        XCTAssertThrowsError(try future.validated(now: now))
        let tooLong = UsageWidgetSnapshot(fetchedAt: now, validUntil: now.addingTimeInterval(901), status: .ready, windows: [])
        XCTAssertThrowsError(try tooLong.validated(now: now))
        let backwards = UsageWidgetSnapshot(fetchedAt: now, validUntil: now.addingTimeInterval(-1), status: .ready, windows: [])
        XCTAssertThrowsError(try backwards.validated(now: now))
        var unsupported = snapshot(); unsupported.version = 2
        XCTAssertThrowsError(try unsupported.validated(now: now))
    }

    func testStaleAndResetBoundariesNeverInventFreshAllowance() throws {
        let reset = now.addingTimeInterval(300), value = snapshot(90, reset: reset)
        let first = try XCTUnwrap(value.windows.first)
        XCTAssertFalse(value.requiresRefresh(for: first, at: reset.addingTimeInterval(-1)))
        XCTAssertTrue(value.requiresRefresh(for: first, at: reset))
        XCTAssertEqual(first.remainingPercent, 10, "The historical allowance is never reset to 100% locally")
        XCTAssertFalse(value.isStale(at: now.addingTimeInterval(899)))
        XCTAssertTrue(value.isStale(at: now.addingTimeInterval(900)))
        XCTAssertEqual(value.timelineDates(now: now), [now, reset, now.addingTimeInterval(900)])
        XCTAssertEqual(value.nextReloadDate(now: now), reset)
        XCTAssertEqual(value.timelineDates(now: now.addingTimeInterval(901)), [now.addingTimeInterval(901)])
        XCTAssertNoThrow(try value.validated(now: now.addingTimeInterval(1200)), "Old snapshots remain valid historical data")
    }

    func testCacheRoundTripCorruptionOversizeAndMissingFallbacks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json"), cache = UsageWidgetCache(fileURL: file)
        XCTAssertEqual(cache.read(now: now).status, .notConnected)
        let value = snapshot(); try cache.write(value, now: now)
        XCTAssertEqual(cache.read(now: now), value)
        try Data("broken".utf8).write(to: file)
        XCTAssertEqual(cache.read(now: now).status, .unavailable)
        try Data(repeating: 0, count: UsageWidgetConstants.maximumFileSize + 1).write(to: file)
        XCTAssertEqual(cache.read(now: now).status, .unavailable)
        XCTAssertThrowsError(try UsageWidgetSnapshot.decode(Data(repeating: 0, count: UsageWidgetConstants.maximumFileSize + 1), now: now))
        try FileManager.default.removeItem(at: file)
        let target = folder.appendingPathComponent("target.json")
        try value.encoded(now: now).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(cache.read(now: now).status, .unavailable)
    }

    func testCacheRechecksTypeAndSizeAfterReplacingTheSamePath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("replaced.json"), cache = UsageWidgetCache(fileURL: file)
        let value = snapshot()
        try cache.write(value, now: now)
        XCTAssertEqual(cache.read(now: now), value)

        let target = folder.appendingPathComponent("target.json")
        try value.encoded(now: now).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(cache.read(now: now).status, .unavailable, "A previously regular path must be rechecked after replacement by a symlink")

        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0, count: UsageWidgetConstants.maximumFileSize + 1).write(to: file, options: .atomic)
        XCTAssertEqual(cache.read(now: now).status, .unavailable, "Replacement with an oversized file cannot reuse the original size")
        try cache.write(value, now: now)
        XCTAssertEqual(cache.read(now: now), value, "A later valid atomic replacement can recover")
    }

    func testStrictUsageDeepLink() {
        XCTAssertTrue(UsageWidgetRoute.matches(UsageWidgetRoute.url))
        for address in ["https://usage", "morispace://calendar", "morispace://usage/", "morispace://usage?x=1", "morispace://usage#x", "morispace://user@usage", "morispace://usage:80", "morispace://usage/other"] {
            XCTAssertFalse(UsageWidgetRoute.matches(URL(string: address)!), address)
        }
    }
}

@MainActor final class UsageWidgetRenderingTests: XCTestCase {
    func testSmallMediumDarkAndStaleLayouts() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(String, UsageWidgetSize, CGFloat, CGFloat, ColorScheme, UsageWidgetSnapshot, Date, Bool)] = [
            ("usage-small-preview", .small, 126, 126, .light, .sample(now: now), now, true),
            ("usage-medium-preview", .medium, 306, 126, .light, .sample(now: now), now, true),
            ("usage-medium-stale-dark", .medium, 306, 126, .dark, .sample(now: now), now.addingTimeInterval(901), false),
            ("usage-small-not-connected", .small, 126, 126, .dark, .empty(.notConnected, now: now), now, false)
        ]
        for (name, size, width, height, scheme, snapshot, date, preview) in cases {
            let content = UsageWidgetContent(date: date, snapshot: snapshot, size: size, isPreview: preview)
                .environment(\.colorScheme, scheme).frame(width: width, height: height)
                .padding(16).background(scheme == .dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: content); renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size, CGSize(width: width + 32, height: height + 32))
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
