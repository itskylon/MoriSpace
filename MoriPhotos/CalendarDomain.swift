import Foundation

struct CalendarLayout {
    var calendar: Calendar
    init(calendar: Calendar? = nil) {
        var value = calendar ?? Calendar(identifier: .gregorian)
        if calendar == nil { value.timeZone = .autoupdatingCurrent; value.locale = .autoupdatingCurrent }
        value.firstWeekday = 2
        self.calendar = value
    }
    func month(containing date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    func day(containing date: Date) -> Date { calendar.startOfDay(for: date) }
    func addingDays(_ days: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
    func addingMonths(_ months: Int, to date: Date) -> Date { calendar.date(byAdding: .month, value: months, to: month(containing: date))! }
    func days(in month: Date) -> [Date] {
        let first = self.month(containing: month)
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        return (0..<((offset + count + 6) / 7 * 7)).map { addingDays($0 - offset, to: first) }
    }
    func visibleInterval(for month: Date) -> DateInterval {
        let dates = days(in: month)
        return DateInterval(start: dates[0], end: addingDays(1, to: dates.last!))
    }
    func events(_ events: [CalendarOccurrence], on date: Date) -> [CalendarOccurrence] {
        let start = day(containing: date), end = addingDays(1, to: start)
        return events.filter {
            // EventKit's end date is exclusive, including all-day events and midnight endings.
            $0.end > $0.start ? $0.start < end && $0.end > start : $0.start >= start && $0.start < end
        }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
    func defaultStart(on date: Date, now: Date = Date()) -> Date {
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = calendar.component(.minute, from: now)
            let rounded = calendar.dateInterval(of: .minute, for: now)!.start
            return calendar.date(byAdding: .minute, value: 30 - minutes % 30, to: rounded)!
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
    }
    func dayID(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    func lunarDate(on date: Date) -> LunarCalendarDate {
        LunarCalendarDate(date: date, displayCalendar: calendar)
    }
}

struct LunarCalendarDate: Equatable {
    let monthName: String
    let dayName: String
    let isLeapMonth: Bool
    let festival: String?
    let isFirstDay: Bool

    var label: String { festival ?? (isFirstDay ? monthName : dayName) }
    var description: String { "农历" + monthName + dayName + (festival.map { " · " + $0 } ?? "") }

    private static let civilCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()
    private static let lunarCalendar: Calendar = {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = civilCalendar.timeZone
        return calendar
    }()
    private static let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
    private static let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
    private static let festivals = [101: "春节", 115: "元宵", 202: "龙抬头", 505: "端午", 707: "七夕",
        715: "中元", 815: "中秋", 909: "重阳", 1208: "腊八"]

    init(date: Date, displayCalendar: Calendar) {
        // Convert the displayed civil date, not its absolute instant. This keeps the
        // Chinese almanac label on the same date when the device is in another zone.
        var civil = displayCalendar.dateComponents([.year, .month, .day], from: date)
        civil.hour = 12
        let noon = Self.civilCalendar.date(from: civil)!
        let lunar = Self.lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: noon)
        let month = lunar.month!, day = lunar.day!
        isLeapMonth = lunar.isLeapMonth == true
        monthName = (isLeapMonth ? "闰" : "") + Self.months[month - 1]
        dayName = Self.days[day - 1]
        isFirstDay = day == 1
        let nextDay = Self.civilCalendar.date(byAdding: .day, value: 1, to: noon)!
        let next = Self.lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: nextDay)
        if next.month == 1, next.day == 1, next.isLeapMonth != true {
            festival = "除夕"
        } else {
            festival = isLeapMonth ? nil : Self.festivals[month * 100 + day]
        }
    }
}

struct CalendarTint: Sendable, Equatable {
    var red: Double = 0.2
    var green: Double = 0.6
    var blue: Double = 0.4
}

struct CalendarSourceItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let account: String
    let isWritable: Bool
    let isLocal: Bool
    let tint: CalendarTint
}

struct CalendarOccurrence: Identifiable, Sendable, Equatable {
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String
    let hasRecurrence: Bool
    var id: String { calendarID + ":" + calendarItemIdentifier + ":" + String(start.timeIntervalSinceReferenceDate) }
}

struct CalendarSnapshot: Sendable {
    var calendars: [CalendarSourceItem] = []
    var events: [CalendarOccurrence] = []
}

enum CalendarAccess: Equatable {
    case notDetermined, full, writeOnly, denied, restricted
    var message: String {
        switch self {
        case .notDetermined: "连接系统日历，即可查看和管理日程。日程保存在你选择的日历账户中。"
        case .writeOnly: "目前只能添加日程。请允许完整日历访问，才能显示已有日程。"
        case .denied: "日历访问已关闭。请在系统设置中允许森空间访问日历。"
        case .restricted: "这台设备限制了日历访问，请检查屏幕使用时间或设备管理设置。"
        case .full: ""
        }
    }
}
