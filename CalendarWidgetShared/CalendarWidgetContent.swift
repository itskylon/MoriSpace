import SwiftUI

enum CalendarWidgetSize { case small, medium }

struct CalendarWidgetContent: View {
    let date: Date
    let snapshot: CalendarWidgetSnapshot
    let size: CalendarWidgetSize
    private let accent = Color(red: 0.15, green: 0.46, blue: 0.37)
    private var layout: CalendarLayout { CalendarLayout() }
    private var lunar: LunarCalendarDate { layout.lunarDate(on: date) }
    private var upcoming: [CalendarWidgetEvent] { snapshot.upcoming(at: date) }

    var body: some View {
        Group {
            if size == .small { small }
            else {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 14) {
                        miniMonth.frame(width: max(100, geometry.size.width * 0.46))
                        Rectangle().fill(.secondary.opacity(0.18)).frame(width: 0.5)
                        agenda(limit: 3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }.foregroundStyle(.primary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                Spacer()
                if let holiday = ChinaHolidaySchedule.day(on: date) { HolidayBadge(kind: holiday.kind) }
                else { Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(accent) }
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(String(layout.calendar.component(.day, from: date)))
                    .font(.system(size: 42, weight: .semibold, design: .rounded)).minimumScaleFactor(0.8)
                Text("\(layout.calendar.component(.month, from: date))月").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(lunar.monthName + lunar.dayName + (lunar.festival.map { " · " + $0 } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if let holiday = ChinaHolidaySchedule.day(on: date) {
                Text(holiday.description).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(holiday.kind == .rest ? Color.red : Color.blue).lineLimit(1).minimumScaleFactor(0.8)
            } else if ChinaHolidaySchedule.coverage(on: date) == nil {
                Text("放假安排未收录").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            if let event = upcoming.first { eventContent(event) }
            else { Text(snapshot.emptyMessage(at: date)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var miniMonth: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(layout.calendar.component(.month, from: date))月").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 2)
                Text(ChinaHolidaySchedule.coverage(on: date) == nil ? "休班未收录" : lunar.festival ?? (lunar.monthName + lunar.dayName))
                    .font(.system(size: 9)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.bottom, 3)
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.system(size: 8)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            let days = layout.days(in: date)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: days.count > 35 ? 1 : 3) {
                ForEach(days, id: \.self) { day in
                    let today = layout.calendar.isDate(day, inSameDayAs: date)
                    let inMonth = layout.calendar.isDate(day, equalTo: date, toGranularity: .month)
                    let holiday = ChinaHolidaySchedule.day(on: day)
                    Link(destination: CalendarWidgetRoute.url(for: day)) {
                        Text(String(layout.calendar.component(.day, from: day)))
                            .font(.system(size: 9, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                            .frame(width: 15, height: 15)
                            .background(today ? accent : .clear, in: Circle())
                            .overlay(alignment: .topTrailing) {
                                if let holiday { HolidayBadge(kind: holiday.kind, fontSize: 5).offset(x: 4, y: -4).opacity(inMonth ? 1 : 0.4) }
                            }
                    }.accessibilityLabel(day.formatted(.dateTime.month().day()) + "，" + layout.lunarDate(on: day).description + (holiday.map { "，" + $0.description } ?? ""))
                }
            }
        }
    }

    private func agenda(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("接下来").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
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
        HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(Color(red: event.red, green: event.green, blue: event.blue)).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(timeLabel(event)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
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
