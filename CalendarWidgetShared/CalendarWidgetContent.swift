import SwiftUI

enum CalendarWidgetSize { case small, medium }

struct CalendarWidgetContent: View {
    let date: Date
    let snapshot: CalendarWidgetSnapshot
    let size: CalendarWidgetSize
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? signal : Color(red: 0.29, green: 0.37, blue: 0.08)
    }
    private var signal: Color { Color(red: 0.81, green: 0.97, blue: 0.28) }
    private var ink: Color { Color(red: 0.08, green: 0.10, blue: 0.10) }
    private var layout: CalendarLayout { CalendarLayout() }
    private var lunar: LunarCalendarDate { layout.lunarDate(on: date) }
    private var upcoming: [CalendarWidgetEvent] { snapshot.upcoming(at: date) }

    var body: some View {
        Group {
            if size == .small { small }
            else {
                GeometryReader { geometry in
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(layout.calendar.component(.month, from: date))月")
                                .font(.system(size: 25, weight: .black, design: .rounded)).tracking(-1)
                                .foregroundStyle(ink).padding(.horizontal, 8).padding(.vertical, 2)
                                .background(signal, in: RoundedRectangle(cornerRadius: 7))
                            Text(String(layout.calendar.component(.year, from: date)))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(ChinaHolidaySchedule.coverage(on: date) == nil ? "休班未收录" : lunar.description)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        HStack(alignment: .top, spacing: 20) {
                            miniMonth.frame(width: max(100, geometry.size.width * 0.47))
                            agenda(limit: geometry.size.height < 165 ? 2 : 3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        }.foregroundStyle(.primary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("\(layout.calendar.component(.month, from: date))月")
                    .font(.system(size: 12, weight: .semibold))
                Text(date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let holiday = ChinaHolidaySchedule.day(on: date) { HolidayBadge(kind: holiday.kind, fontSize: 8) }
            }
            HStack(alignment: .center, spacing: 9) {
                Text(String(layout.calendar.component(.day, from: date)))
                    .font(.system(size: 58, weight: .black, design: .rounded)).monospacedDigit()
                    .tracking(-3).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 74, height: 66).foregroundStyle(ink)
                    .background(signal, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(lunar.monthName + lunar.dayName).font(.system(size: 10, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let holiday = ChinaHolidaySchedule.day(on: date) {
                        Text(holiday.description).font(.system(size: 9)).foregroundStyle(accent).lineLimit(2)
                    } else if let festival = lunar.festival {
                        Text(festival).font(.system(size: 10)).foregroundStyle(accent).lineLimit(1)
                    } else if ChinaHolidaySchedule.coverage(on: date) == nil {
                        Text("放假安排未收录").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
            if let event = upcoming.first { eventContent(event) }
            else {
                Text(snapshot.emptyMessage(at: date)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var miniMonth: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, title in
                    Text(title).font(.system(size: 8, weight: .medium))
                        .foregroundStyle(index >= 5 ? accent.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { geometry in
                let days = layout.days(in: date)
                let rows = days.count / 7
                let rowHeight = geometry.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(days[(row * 7)..<(row * 7 + 7)]), id: \.self) { day in
                                miniatureDay(day, height: rowHeight)
                            }
                        }.frame(height: rowHeight)
                    }
                }
            }
        }
    }

    private func miniatureDay(_ day: Date, height: CGFloat) -> some View {
        let today = layout.calendar.isDate(day, inSameDayAs: date)
        let inMonth = layout.calendar.isDate(day, equalTo: date, toGranularity: .month)
        let holiday = ChinaHolidaySchedule.day(on: day)
        return Link(destination: CalendarWidgetRoute.url(for: day)) {
            Text(String(layout.calendar.component(.day, from: day)))
                .font(.system(size: 10, weight: today ? .black : .medium)).monospacedDigit()
                .foregroundStyle(today ? ink : inMonth ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: min(20, height), height: min(20, height))
                .background(today ? signal : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topTrailing) {
                    if let holiday { HolidayBadge(kind: holiday.kind, fontSize: 5).offset(x: 3, y: -1).opacity(inMonth ? 1 : 0.4) }
                }
                .frame(maxWidth: .infinity)
        }.accessibilityLabel(day.formatted(.dateTime.month().day()) + "，" + layout.lunarDate(on: day).description + (holiday.map { "，" + $0.description } ?? ""))
    }

    private func agenda(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Rectangle().fill(signal).frame(width: 12, height: 3)
                Text("接下来").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            if upcoming.isEmpty {
                Text(snapshot.emptyMessage(at: date)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            } else {
                ForEach(upcoming.prefix(limit)) { event in
                    Link(destination: CalendarWidgetRoute.url(for: max(event.start, layout.day(containing: date)))) { eventContent(event) }
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func eventContent(_ event: CalendarWidgetEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1).fill(Color(red: event.red, green: event.green, blue: event.blue))
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(timeLabel(event)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true).privacySensitive()
    }
    private func timeLabel(_ event: CalendarWidgetEvent) -> String {
        let sameDay = layout.calendar.isDate(event.start, inSameDayAs: date)
        let prefix = sameDay ? "今天 " : event.start.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " "
        if event.isAllDay { return event.start < layout.day(containing: date) ? "全天 · 进行中" : prefix + "全天" }
        if event.start <= date && event.end > date { return "进行中 · " + event.end.formatted(.dateTime.hour().minute()) + " 结束" }
        return prefix + event.start.formatted(.dateTime.hour().minute())
    }
}
