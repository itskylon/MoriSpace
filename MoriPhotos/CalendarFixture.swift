#if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
import Foundation

@MainActor final class CalendarPreviewProvider: CalendarProviding {
    var access: CalendarAccess { .full }
    func requestAccess() async throws {}
    func snapshot(in interval: DateInterval) async throws -> CalendarSnapshot {
        let layout = CalendarLayout(), day = layout.day(containing: Date())
        let sources = [
            CalendarSourceItem(id: "preview-personal", title: "个人（示例）", account: "隔离测试", isWritable: false, isLocal: true, tint: CalendarTint()),
            CalendarSourceItem(id: "preview-work", title: "工作（示例）", account: "隔离测试", isWritable: false, isLocal: true, tint: CalendarTint(red: 0.3, green: 0.5, blue: 0.85))
        ]
        let events = [0, 2, 5, 9, 14].map { offset -> CalendarOccurrence in
            let start = layout.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: layout.addingDays(offset, to: day))!
            return CalendarOccurrence(eventIdentifier: "preview-\(offset)", calendarItemIdentifier: "preview-\(offset)", calendarID: sources[offset % 2].id,
                title: offset == 0 ? "周末徒步（示例）" : "产品讨论（示例）", start: start, end: start.addingTimeInterval(3600), isAllDay: false, location: "", hasRecurrence: false)
        }
        return CalendarSnapshot(calendars: sources, events: events.filter { $0.start < interval.end && $0.end > interval.start })
    }
    func presentation(for occurrence: CalendarOccurrence?, on date: Date, preferredCalendarID: String?) throws -> CalendarPresentation { throw CalendarFailure.previewOnly }
}
#endif

#if DEBUG && targetEnvironment(simulator)
import EventKit

// Real EventKit acceptance uses only this explicitly-owned local simulator calendar.
// Never compiled into device or Mac builds, and never creates calendars without the test launch flag.
@MainActor enum CalendarLiveFixture {
    static func prepare(in store: EKEventStore) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarFailure.noAccess }
        let title = "森空间日历验收（仅模拟器）", key = "calendar.liveFixture.identifier"
        if let id = UserDefaults.standard.string(forKey: key), let existing = store.calendar(withIdentifier: id),
           existing.title == title, existing.source.sourceType == .local {
            if ProcessInfo.processInfo.arguments.contains("--reset-calendar-live-fixture") { try store.removeCalendar(existing, commit: true) }
            else { return id }
        }
        guard let source = store.sources.first(where: { $0.sourceType == .local }) else { throw CalendarFailure.noWritableCalendar }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: key)
        let layout = CalendarLayout(), today = layout.day(containing: Date())
        for (index, title) in ["日历验收·徒步", "日历验收·生日", "日历验收·每周会议"].enumerated() {
            let event = EKEvent(eventStore: store); event.calendar = calendar; event.title = title
            event.startDate = layout.calendar.date(bySettingHour: index == 1 ? 0 : 10 + index, minute: 0, second: 0, of: today)!
            event.endDate = index == 1 ? layout.addingDays(1, to: today) : event.startDate.addingTimeInterval(3600)
            event.isAllDay = index == 1
            if index == 2 { event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4))) }
            try store.save(event, span: .thisEvent)
        }
        return calendar.calendarIdentifier
    }
}
#endif
