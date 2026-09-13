import Foundation

enum CalendarWidgetConstants {
    static let kind = "MoriCalendarWidget"
    static let scheme = "morispace"
}

struct CalendarWidgetEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let red: Double
    let green: Double
    let blue: Double

    func isUpcoming(at date: Date) -> Bool { end > start ? end > date : start >= date }
}

struct CalendarWidgetSnapshot: Codable, Equatable {
    enum Status: String, Codable { case ready, permissionRequired, unavailable }
    let status: Status
    let updatedAt: Date
    let validUntil: Date
    let events: [CalendarWidgetEvent]

    static func empty(_ status: Status, now: Date = Date()) -> Self {
        Self(status: status, updatedAt: now, validUntil: now.addingTimeInterval(24 * 3600), events: [])
    }
    func upcoming(at date: Date) -> [CalendarWidgetEvent] {
        guard status == .ready, date < validUntil else { return [] }
        return events.filter { $0.isUpcoming(at: date) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
    func emptyMessage(at date: Date) -> String {
        if status == .permissionRequired { return "打开 App 连接日历" }
        if status == .unavailable || date >= validUntil { return "打开日历更新日程" }
        return "近期没有日程"
    }
    func timelineDates(now: Date, calendar: Calendar = CalendarLayout().calendar) -> [Date] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let horizon = now.addingTimeInterval(24 * 3600)
        var dates = Set([now, tomorrow])
        for hour in 1...24 { dates.insert(now.addingTimeInterval(Double(hour) * 3600)) }
        for event in upcoming(at: now).prefix(40) {
            for date in [event.start, event.end] where date > now && date <= horizon { dates.insert(date) }
        }
        if validUntil > now && validUntil <= horizon { dates.insert(validUntil) }
        return dates.sorted()
    }
}

struct CalendarWidgetCache {
    let fileURL: URL?
    init(fileURL: URL?) { self.fileURL = fileURL }
    static var shared: Self {
        let group = Bundle.main.object(forInfoDictionaryKey: "MoriCalendarAppGroup") as? String
        let folder = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        return Self(fileURL: folder?.appendingPathComponent("calendar-widget-v1.json"))
    }
    func read() -> CalendarWidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(CalendarWidgetSnapshot.self, from: data) else {
            return .empty(.permissionRequired)
        }
        return snapshot
    }
    func write(_ snapshot: CalendarWidgetSnapshot) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(snapshot)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }
}

enum CalendarWidgetRoute {
    static func url(for date: Date, calendar: Calendar = CalendarLayout().calendar) -> URL {
        var components = URLComponents()
        components.scheme = CalendarWidgetConstants.scheme; components.host = "calendar"
        components.queryItems = [URLQueryItem(name: "date", value: CalendarLayout(calendar: calendar).dayID(date))]
        return components.url!
    }
    static func date(from url: URL, calendar: Calendar = CalendarLayout().calendar) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == CalendarWidgetConstants.scheme, components.host == "calendar",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let query = components.queryItems, query.count == 1, query[0].name == "date",
              let value = query[0].value, value.count == 10 else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              CalendarLayout(calendar: calendar).dayID(date) == value else { return nil }
        return date
    }
}
