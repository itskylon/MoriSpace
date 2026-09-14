import Foundation

struct ChinaHolidayDay: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case rest, work }
    let name: String
    let kind: Kind
    var marker: String { kind == .rest ? "休" : "班" }
    var description: String { name + (kind == .rest ? "放假" : "调休上班") }
}

struct ChinaHolidayYear: Sendable {
    let source: URL
    let days: [String: ChinaHolidayDay]
}

/// Mainland China's published nationwide holiday arrangements, including make-up
/// workdays. Missing dates and unsupported years are deliberately not inferred.
enum ChinaHolidaySchedule {
    static let years: [Int: ChinaHolidayYear] = [
        2025: makeYear(2025, source: "https://www.gov.cn/zhengce/zhengceku/202411/content_6986383.htm", periods: [
            ("元旦", "01-01", "01-01", []),
            ("春节", "01-28", "02-04", ["01-26", "02-08"]),
            ("清明节", "04-04", "04-06", []),
            ("劳动节", "05-01", "05-05", ["04-27"]),
            ("端午节", "05-31", "06-02", []),
            ("国庆节、中秋节", "10-01", "10-08", ["09-28", "10-11"])
        ]),
        2026: makeYear(2026, source: "https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm", periods: [
            ("元旦", "01-01", "01-03", ["01-04"]),
            ("春节", "02-15", "02-23", ["02-14", "02-28"]),
            ("清明节", "04-04", "04-06", []),
            ("劳动节", "05-01", "05-05", ["05-09"]),
            ("端午节", "06-19", "06-21", []),
            ("中秋节", "09-25", "09-27", []),
            ("国庆节", "10-01", "10-07", ["09-20", "10-10"])
        ])
    ]

    static func day(on date: Date, calendar: Calendar = CalendarLayout().calendar) -> ChinaHolidayDay? {
        let year = calendar.component(.year, from: date)
        return years[year]?.days[CalendarLayout(calendar: calendar).dayID(date)]
    }

    static func coverage(on date: Date, calendar: Calendar = CalendarLayout().calendar) -> ChinaHolidayYear? {
        years[calendar.component(.year, from: date)]
    }

    private static func makeYear(_ year: Int, source: String, periods: [(String, String, String, [String])]) -> ChinaHolidayYear {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let layout = CalendarLayout(calendar: calendar)
        func date(_ value: String) -> Date {
            let parts = value.split(separator: "-").map { Int($0)! }
            return calendar.date(from: DateComponents(year: year, month: parts[0], day: parts[1]))!
        }
        var days: [String: ChinaHolidayDay] = [:]
        func add(_ date: Date, name: String, kind: ChinaHolidayDay.Kind) {
            let key = layout.dayID(date)
            precondition(days[key] == nil, "Conflicting published holiday date: \(key)")
            days[key] = ChinaHolidayDay(name: name, kind: kind)
        }
        for (name, first, last, workdays) in periods {
            var current = date(first)
            let end = date(last)
            while current <= end {
                add(current, name: name, kind: .rest)
                current = layout.addingDays(1, to: current)
            }
            for workday in workdays { add(date(workday), name: name, kind: .work) }
        }
        return ChinaHolidayYear(source: URL(string: source)!, days: days)
    }
}
