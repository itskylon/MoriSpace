import XCTest
import SwiftUI
@testable import MoriPhotos

@MainActor final class LunarMonthWidgetRenderingTests: XCTestCase {
    func testLunarMonthLayouts() throws {
        let cases: [(String, String, CGFloat, CGFloat, Bool, ColorScheme)] = [
            ("lunar-month-medium-festival", "2026-09-25T12:00:00+08:00", 338, 158, false, .light),
            ("lunar-month-compact-six-weeks", "2026-11-01T12:00:00+08:00", 292, 141, false, .light),
            ("lunar-month-large-dark", "2026-09-25T12:00:00+08:00", 338, 354, true, .dark)
        ]
        for (name, value, width, height, isLarge, scheme) in cases {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: value))
            let content = LunarMonthWidgetContent(date: date, isLarge: isLarge)
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: height)
                .background(scheme == .dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size, CGSize(width: width, height: height))
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

final class CalendarWidgetDataTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func event(start: Date, end: Date, id: String = "event") -> CalendarWidgetEvent {
        CalendarWidgetEvent(id: id, title: "测试", start: start, end: end, isAllDay: false, red: 0.2, green: 0.5, blue: 0.4)
    }
    func testEndedEventsAndExpiredSnapshotsNeverShowAsUpcoming() {
        let now = date("2026-09-14T00:00:00+08:00")
        let ended = event(start: now.addingTimeInterval(-3600), end: now, id: "ended")
        let ongoing = event(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(1800), id: "ongoing")
        let instant = event(start: now, end: now, id: "instant")
        let snapshot = CalendarWidgetSnapshot(status: .ready, updatedAt: now, validUntil: now.addingTimeInterval(3600), events: [ended, instant, ongoing])
        XCTAssertEqual(snapshot.upcoming(at: now).map(\.id), ["ongoing", "instant"])
        XCTAssertTrue(snapshot.upcoming(at: snapshot.validUntil).isEmpty)
        XCTAssertEqual(snapshot.emptyMessage(at: snapshot.validUntil), "打开日历更新日程")
    }
    func testTimelineIncludesLocalMidnightDSTAndEventBoundaries() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date("2026-03-08T00:00:00-08:00"), midnight = date("2026-03-09T00:00:00-07:00")
        let start = now.addingTimeInterval(3700), end = now.addingTimeInterval(7600)
        let snapshot = CalendarWidgetSnapshot(status: .ready, updatedAt: now, validUntil: now.addingTimeInterval(12000), events: [event(start: start, end: end)])
        let dates = snapshot.timelineDates(now: now, calendar: calendar)
        XCTAssertEqual(dates.first, now); XCTAssertEqual(dates, Array(Set(dates)).sorted())
        XCTAssertTrue(dates.contains(midnight)); XCTAssertTrue(dates.contains(start)); XCTAssertTrue(dates.contains(end)); XCTAssertTrue(dates.contains(snapshot.validUntil))
    }
    func testDeepLinkRoundTripsDisplayedDayAndRejectsInvalidRoutes() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let date = date("2026-09-25T00:00:00+12:00")
        XCTAssertEqual(CalendarWidgetRoute.date(from: CalendarWidgetRoute.url(for: date, calendar: calendar), calendar: calendar), date)
        for value in ["https://calendar?date=2026-09-25", "morispace://files?date=2026-09-25", "morispace://calendar?date=2026-02-30",
            "morispace://calendar?date=2026-09-25&date=2026-09-26", "morispace://calendar?date=2026-09-25#x", "morispace://calendar?date=2026-9-25"] {
            XCTAssertNil(CalendarWidgetRoute.date(from: URL(string: value)!, calendar: calendar), value)
        }
    }
    func testCacheRoundTripAndCorruptFileFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("snapshot.json"), cache = CalendarWidgetCache(fileURL: file)
        let snapshot = CalendarWidgetSnapshot.empty(.ready)
        try cache.write(snapshot); XCTAssertEqual(cache.read(), snapshot)
        try Data("broken".utf8).write(to: file)
        XCTAssertEqual(cache.read().status, .permissionRequired)
    }
}

@MainActor final class CalendarWidgetPublishingTests: XCTestCase {
    private var folder: URL!
    private var cache: CalendarWidgetCache!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cache = CalendarWidgetCache(fileURL: folder.appendingPathComponent("widget.json"))
        suite = "CalendarWidgetPublishingTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
    func testWidgetUsesCurrentWeekAndVisibleCalendarsRatherThanBrowsedMonth() async {
        let now = Date(), provider = WidgetTestProvider()
        let store = CalendarStore(provider: provider, defaults: defaults, now: now, widgetCache: cache)
        store.moveMonth(-12); store.setVisible(false, id: "hidden")
        let request = Task { await store.refreshWidgetSnapshot(now: now) }; await provider.waitForRequest()
        XCTAssertEqual(provider.interval?.start, store.layout.day(containing: now))
        XCTAssertEqual(provider.interval?.end, store.layout.addingDays(7, to: store.layout.day(containing: now)))
        provider.resume(events: [provider.event("shown", now: now), provider.event("hidden", now: now)])
        await request.value
        XCTAssertEqual(cache.read().events.map(\.title), ["shown"])
    }
    func testPermissionRevocationClearsCacheAndRejectsOlderQuery() async throws {
        let provider = WidgetTestProvider(), store = CalendarStore(provider: provider, defaults: defaults, widgetCache: cache)
        try cache.write(.empty(.ready))
        let request = Task { await store.refreshWidgetSnapshot() }; await provider.waitForRequest()
        provider.access = .denied
        await store.refreshWidgetSnapshot()
        XCTAssertEqual(cache.read().status, .permissionRequired)
        provider.resume(events: [provider.event("private", now: Date())]); await request.value
        XCTAssertEqual(cache.read().status, .permissionRequired); XCTAssertTrue(cache.read().events.isEmpty)
    }
}

@MainActor private final class WidgetTestProvider: CalendarProviding {
    var access = CalendarAccess.full
    var interval: DateInterval?
    var request: CheckedContinuation<CalendarSnapshot, Error>?
    func requestAccess() async throws {}
    func snapshot(in interval: DateInterval) async throws -> CalendarSnapshot {
        self.interval = interval
        return try await withCheckedThrowingContinuation { request = $0 }
    }
    func presentation(for occurrence: CalendarOccurrence?, on date: Date, preferredCalendarID: String?) throws -> CalendarPresentation { throw CalendarFailure.previewOnly }
    func waitForRequest() async {
        for _ in 0..<1000 { if request != nil { return }; await Task.yield() }
        XCTFail("Widget query did not start")
    }
    func resume(events: [CalendarOccurrence]) {
        request?.resume(returning: CalendarSnapshot(events: events)); request = nil
    }
    func event(_ calendar: String, now: Date) -> CalendarOccurrence {
        CalendarOccurrence(eventIdentifier: calendar, calendarItemIdentifier: calendar, calendarID: calendar, title: calendar,
            start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), isAllDay: false, location: "", hasRecurrence: false)
    }
}
