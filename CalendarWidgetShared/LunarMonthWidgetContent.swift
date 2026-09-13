import SwiftUI

/// A date-only calendar. Rendering never depends on EventKit or a shared snapshot.
struct LunarMonthWidgetContent: View {
    let date: Date
    let isLarge: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var layout: CalendarLayout { CalendarLayout() }
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.40, green: 0.79, blue: 0.66) : Color(red: 0.15, green: 0.46, blue: 0.37)
    }

    var body: some View {
        let days = layout.days(in: date)
        let rows = days.count / 7
        VStack(spacing: 0) {
            header.frame(height: isLarge ? 42 : 22)
            HStack(spacing: 0) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, title in
                    Text(title).font(.system(size: isLarge ? 11 : 9, weight: .medium))
                        .foregroundStyle(index >= 5 ? accent : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: isLarge ? 26 : 14)
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(days[(row * 7)..<(row * 7 + 7)]), id: \.self) { day in
                                dayCell(day, rowHeight: rowHeight)
                            }
                        }.frame(height: rowHeight)
                    }
                }
            }
        }
        .padding(.horizontal, isLarge ? 16 : 10)
        .padding(.vertical, isLarge ? 12 : 8)
        .foregroundStyle(.primary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(layout.calendar.component(.month, from: date))月")
                .font(.system(size: isLarge ? 24 : 17, weight: .bold, design: .rounded))
            Text(String(layout.calendar.component(.year, from: date)))
                .font(.system(size: isLarge ? 12 : 10)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(layout.lunarDate(on: date).description)
                .font(.system(size: isLarge ? 12 : 10, weight: .medium))
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func dayCell(_ day: Date, rowHeight: CGFloat) -> some View {
        let lunar = layout.lunarDate(on: day)
        let today = layout.calendar.isDate(day, inSameDayAs: date)
        let inMonth = layout.calendar.isDate(day, equalTo: date, toGranularity: .month)
        // On compact six-week widgets, a single line keeps the lunar text readable.
        let inline = !isLarge && rowHeight < 26
        let dayColor: Color = today ? (colorScheme == .dark ? .black : .white) : inMonth ? .primary : .secondary.opacity(0.45)
        let lunarColor: Color = today ? dayColor : !inMonth ? .secondary.opacity(0.4) : lunar.festival != nil ? .orange : .secondary
        return Link(destination: CalendarWidgetRoute.url(for: day)) {
            let content = Group {
                Text(String(layout.calendar.component(.day, from: day)))
                    .font(.system(size: isLarge ? 19 : inline ? 11 : 12, weight: today ? .bold : .medium, design: .rounded))
                    .foregroundStyle(dayColor)
                    .lineLimit(1).minimumScaleFactor(0.9)
                    .frame(width: inline ? 18 : nil)
                Text(lunar.label)
                    .font(.system(size: isLarge ? 10 : 8, weight: lunar.festival == nil ? .regular : .medium))
                    .foregroundStyle(lunarColor).lineLimit(1).minimumScaleFactor(inline ? 0.65 : 0.8)
            }
            Group {
                if inline { HStack(spacing: 2) { content } }
                else { VStack(spacing: isLarge ? 3 : 0) { content } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(today ? accent : .clear, in: RoundedRectangle(cornerRadius: isLarge ? 10 : 6))
            .padding(.horizontal, isLarge ? 3 : 1)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.year().month().day()) + "，" + lunar.description + (today ? "，今天" : ""))
    }
}
