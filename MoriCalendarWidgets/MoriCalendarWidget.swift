import SwiftUI
import WidgetKit

struct MoriCalendarEntry: TimelineEntry {
    let date: Date
    let snapshot: CalendarWidgetSnapshot
}

struct MoriCalendarTimeline: TimelineProvider {
    func placeholder(in context: Context) -> MoriCalendarEntry {
        MoriCalendarEntry(date: Date(), snapshot: .empty(.ready))
    }
    func getSnapshot(in context: Context, completion: @escaping (MoriCalendarEntry) -> Void) {
        completion(MoriCalendarEntry(date: Date(), snapshot: CalendarWidgetCache.shared.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MoriCalendarEntry>) -> Void) {
        let now = Date(), snapshot = CalendarWidgetCache.shared.read()
        let entries = snapshot.timelineDates(now: now).map { MoriCalendarEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

struct MoriCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoriCalendarEntry
    var body: some View {
        CalendarWidgetContent(date: entry.date, snapshot: entry.snapshot, size: family == .systemSmall ? .small : .medium)
            .containerBackground(.background, for: .widget)
            .widgetURL(CalendarWidgetRoute.url(for: destinationDate))
    }
    private var destinationDate: Date {
        guard family == .systemSmall, let next = entry.snapshot.upcoming(at: entry.date).first else { return entry.date }
        return max(next.start, CalendarLayout().day(containing: entry.date))
    }
}

struct MoriCalendarWidget: Widget {
    let kind = CalendarWidgetConstants.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MoriCalendarTimeline()) { MoriCalendarWidgetView(entry: $0) }
            .configurationDisplayName("日历与农历")
            .description("查看日期、农历和近期日程，轻点打开森空间。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MoriMonthEntry: TimelineEntry { let date: Date }

struct MoriMonthTimeline: TimelineProvider {
    func placeholder(in context: Context) -> MoriMonthEntry { MoriMonthEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (MoriMonthEntry) -> Void) {
        completion(MoriMonthEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MoriMonthEntry>) -> Void) {
        let now = Date(), layout = CalendarLayout()
        let midnight = layout.day(containing: now)
        // Calendar arithmetic preserves the local date across daylight-saving changes.
        let entries = [MoriMonthEntry(date: now)] + (1...7).map { MoriMonthEntry(date: layout.addingDays($0, to: midnight)) }
        completion(Timeline(entries: entries, policy: .after(entries[1].date)))
    }
}

struct MoriMonthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoriMonthEntry
    var body: some View {
        LunarMonthWidgetContent(date: entry.date, isLarge: family == .systemLarge)
            .containerBackground(.background, for: .widget)
            .widgetURL(CalendarWidgetRoute.url(for: entry.date))
    }
}

struct MoriMonthWidget: Widget {
    let kind = "MoriLunarMonthWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MoriMonthTimeline()) { MoriMonthWidgetView(entry: $0) }
            .configurationDisplayName("纯日历 · 农历")
            .description("整月日期、每日农历与传统节日，无需日历授权。")
            .supportedFamilies([.systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

@main struct MoriWidgets: WidgetBundle {
    var body: some Widget {
        MoriCalendarWidget()
        MoriMonthWidget()
    }
}
