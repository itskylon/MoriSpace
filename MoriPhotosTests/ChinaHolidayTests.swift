import XCTest
import SwiftUI
@testable import MoriPhotos

final class ChinaHolidayScheduleTests: XCTestCase {
    func testOfficialDateSets() throws {
        // Independently transcribed from 国办发明电〔2024〕12号 and〔2025〕7号.
        let expected: [(Int, String, String)] = [
            (2025, "01-01 01-28 01-29 01-30 01-31 02-01 02-02 02-03 02-04 04-04 04-05 04-06 05-01 05-02 05-03 05-04 05-05 05-31 06-01 06-02 10-01 10-02 10-03 10-04 10-05 10-06 10-07 10-08", "01-26 02-08 04-27 09-28 10-11"),
            (2026, "01-01 01-02 01-03 02-15 02-16 02-17 02-18 02-19 02-20 02-21 02-22 02-23 04-04 04-05 04-06 05-01 05-02 05-03 05-04 05-05 06-19 06-20 06-21 09-25 09-26 09-27 10-01 10-02 10-03 10-04 10-05 10-06 10-07", "01-04 02-14 02-28 05-09 09-20 10-10")
        ]
        for (year, rest, work) in expected {
            let schedule = try XCTUnwrap(ChinaHolidaySchedule.years[year])
            let restKeys = Set(rest.split(separator: " ").map { "\(year)-\($0)" })
            let workKeys = Set(work.split(separator: " ").map { "\(year)-\($0)" })
            XCTAssertEqual(Set(schedule.days.filter { $0.value.kind == .rest }.keys), restKeys)
            XCTAssertEqual(Set(schedule.days.filter { $0.value.kind == .work }.keys), workKeys)
            XCTAssertTrue(restKeys.isDisjoint(with: workKeys))
            XCTAssertEqual(schedule.source.host, "www.gov.cn")
        }
    }

    func testBoundariesWeekendsAndUncollectedYears() {
        func day(_ value: String) -> ChinaHolidayDay? {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            let date = ISO8601DateFormatter().date(from: value + "T12:00:00+08:00")!
            return ChinaHolidaySchedule.day(on: date, calendar: calendar)
        }
        XCTAssertEqual(day("2025-02-04")?.description, "春节放假")
        XCTAssertNil(day("2025-02-05"))
        XCTAssertEqual(day("2026-02-14")?.kind, .work)
        XCTAssertEqual(day("2026-02-15")?.kind, .rest)
        XCTAssertNil(day("2026-02-24"))
        XCTAssertNil(day("2026-09-19")) // Ordinary Saturday, not a published holiday.
        XCTAssertEqual(day("2026-09-20")?.description, "国庆节调休上班")
        XCTAssertEqual(day("2026-09-25")?.description, "中秋节放假")
        XCTAssertEqual(day("2026-10-10")?.marker, "班")
        XCTAssertNil(day("2027-01-01"))
        XCTAssertNil(ChinaHolidaySchedule.years[2027])
        XCTAssertNil(ChinaHolidaySchedule.years[2024])
    }

    func testUsesTheDisplayedDateAcrossTimeZones() {
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "Pacific/Kiritimati"] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20))!
            XCTAssertEqual(ChinaHolidaySchedule.day(on: date, calendar: calendar)?.kind, .work, zone)
        }
    }
}

@MainActor final class HolidayWidgetRenderingTests: XCTestCase {
    func testHolidayWidgetLayouts() throws {
        func date(_ day: String) -> Date { ISO8601DateFormatter().date(from: day + "T12:00:00+08:00")! }
        let rest = date("2026-09-25"), work = date("2026-09-20")
        let event = CalendarWidgetEvent(id: "sample", title: "项目讨论（示例）", start: rest.addingTimeInterval(3600), end: rest.addingTimeInterval(7200), isAllDay: false, red: 0.2, green: 0.6, blue: 0.4)
        let snapshot = CalendarWidgetSnapshot(status: .ready, updatedAt: rest, validUntil: rest.addingTimeInterval(86400), events: [event])
        let cases: [(String, AnyView, CGFloat, CGFloat, ColorScheme)] = [
            ("holiday-pure-medium", AnyView(LunarMonthWidgetContent(date: rest, isLarge: false)), 338, 158, .light),
            ("holiday-pure-large-dark", AnyView(LunarMonthWidgetContent(date: work, isLarge: true)), 338, 354, .dark),
            ("holiday-compact-six-weeks", AnyView(LunarMonthWidgetContent(date: date("2025-06-01"), isLarge: false)), 292, 141, .light),
            ("holiday-small-agenda", AnyView(CalendarWidgetContent(date: rest, snapshot: snapshot, size: .small)), 138, 138, .light),
            ("holiday-medium-agenda", AnyView(CalendarWidgetContent(date: rest, snapshot: snapshot, size: .medium)), 306, 126, .light),
            ("holiday-uncollected-year", AnyView(LunarMonthWidgetContent(date: date("2027-01-01"), isLarge: false)), 338, 158, .light)
        ]
        for (name, view, width, height, scheme) in cases {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).frame(width: width, height: height).background(scheme == .dark ? Color.black : Color.white))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
