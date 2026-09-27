import SwiftUI
import EventKit
import Combine

struct CalendarHomeView: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.wideWorkspace) private var wide
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var compactDayHeight: CGFloat = 66
    @ScaledMetric(relativeTo: .caption) private var eventTimeWidth: CGFloat = 50
    @ScaledMetric(relativeTo: .largeTitle) private var monthNumeralSize: CGFloat = 58
    @State private var presentation: CalendarPresentation?
    @State private var showingCalendars = false
    var isActive = true

    var body: some View {
        GeometryReader { geometry in
            let desktop = wide && geometry.size.width >= 800 && !dynamicTypeSize.isAccessibilitySize
            Group {
                if store.access != .full { permissionView }
                else {
                    VStack(spacing: 0) {
                        controls(desktop: desktop)
                        if let error = store.error {
                            ErrorBanner(message: error).padding(.horizontal, desktop ? 24 : 16).padding(.bottom, 12)
                        }
                        if store.calendars.isEmpty {
                            if store.isLoading { ProgressView("正在读取日历…").frame(maxHeight: .infinity) }
                            else {
                                ContentUnavailableView("没有可用日历", systemImage: "calendar.badge.plus", description: Text("在苹果日历中添加账户或创建日历后，点击刷新。"))
                            }
                        } else if desktop {
                            HStack(alignment: .top, spacing: 0) {
                                ScrollView {
                                    primaryContent(desktop: true, availableHeight: geometry.size.height)
                                    calendarFooter.padding(.horizontal, 28).padding(.vertical, 18)
                                }
                                .frame(maxWidth: .infinity)
                                .refreshable { await store.refresh() }
                                Rectangle().fill(NASStyle.outline).frame(width: 1)
                                ScrollView {
                                    agenda(for: store.selectedDate).padding(20)
                                }
                                .frame(width: min(380, max(290, geometry.size.width * 0.30)))
                                .background(NASStyle.surface)
                            }

                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    primaryContent(desktop: false, availableHeight: geometry.size.height)
                                    if store.displayMode == .month {
                                        agenda(for: store.selectedDate).padding(.horizontal, 16).padding(.vertical, 12)
                                    }
                                    calendarFooter.padding(.horizontal, 20).padding(.vertical, 16)
                                }
                            }.refreshable { await store.refresh() }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NASStyle.canvas)
        }
        .workspaceNavigationTitle("日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingCalendars = true } label: { Image(systemName: "calendar.badge.checkmark") }
                        .accessibilityLabel("选择显示的日历").accessibilityIdentifier("calendarSources")
                        .disabled(store.access != .full)
                    Button { openNew() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建日程").accessibilityIdentifier("calendarNewEvent")
                        .keyboardShortcut("n", modifiers: .command).disabled(!store.canCreate)
                }
            }
        }
        .sheet(isPresented: $showingCalendars) { CalendarSourcesView().environmentObject(store).desktopSheet(width: 460, height: 500) }
        .sheet(item: $presentation, onDismiss: { Task { await store.refresh() } }) { item in
            CalendarEventSheet(presentation: item, saved: { date, calendar in store.didSave(start: date, calendarID: calendar) }, close: { presentation = nil })
                .ignoresSafeArea(edges: .bottom).interactiveDismissDisabled()
                .desktopSheet(width: 600, height: 650)
        }
        .task(id: loadKey) {
            guard isActive, phase == .active else { return }
            await store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            if isActive, phase == .active, presentation == nil { Task { await store.refresh() } }
        }
        .onChange(of: store.access) { _, access in if access != .full { presentation = nil; showingCalendars = false } }
    }
    private var loadKey: String { "\(store.month.timeIntervalSinceReferenceDate)-\(isActive)-\(phase)" }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "calendar")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(NASStyle.ink)
                .frame(width: 64, height: 64)
                .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                Text("连接系统日历").font(.largeTitle.weight(.bold))
                Text(store.access.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.error { ErrorBanner(message: error) }
            if store.access == .notDetermined || store.access == .writeOnly {
                Button { Task { await store.requestAccess() } } label: {
                    HStack(spacing: 8) {
                        if store.isRequestingAccess { ProgressView() }
                        Text(store.isRequestingAccess ? "正在请求访问…" : "允许访问日历")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }.padding(.horizontal, 16).frame(minHeight: 48)
                        .foregroundStyle(NASStyle.ink)
                        .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                    .disabled(store.isRequestingAccess).accessibilityIdentifier("calendarRequestAccess")
            } else if store.access == .denied {
                Button("打开系统设置", action: openSettings).buttonStyle(.borderedProminent).tint(Theme.accent)
                    .accessibilityIdentifier("calendarOpenSettings")
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "icloud").foregroundStyle(Theme.accent)
                Text("使用 iCloud 日历，日程会由系统同步到其他设备。本机日历仅保存在当前设备。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).padding(.top, 2)
        }.padding(28).frame(maxWidth: 420).accessibilityIdentifier("calendarPermissionView")
    }

    private func controls(desktop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if desktop {
                HStack(spacing: 24) {
                    monthTitle
                    displayModes
                    Spacer(minLength: 12)
                    monthNavigation
                    refreshButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { monthTitle; Spacer(minLength: 0); monthNavigation }
                    VStack(alignment: .leading, spacing: 4) { monthTitle; monthNavigation }
                }
                HStack { displayModes; Spacer(); refreshButton }
            }
        }
        .padding(.horizontal, desktop ? 28 : 20)
        .padding(.top, desktop ? 12 : 4).padding(.bottom, desktop ? 18 : 4)
    }

    private var monthTitle: some View {
        let parts = store.layout.calendar.dateComponents([.year, .month], from: store.month)
        return (Text(String(format: "%02d", parts.month!)).font(.system(size: min(monthNumeralSize, 88), weight: .black, design: .rounded)).tracking(-3)
                + Text(" / ").font(.title3.weight(.light)).foregroundColor(.secondary)
                + Text(String(parts.year!)).font(.subheadline.weight(.semibold)).foregroundColor(.secondary))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("\(String(parts.year!))年 \(parts.month!)月")
            .accessibilityIdentifier("calendarMonthTitle")
    }

    private var monthNavigation: some View {
        HStack(spacing: 0) {
            Button { store.moveMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.callout.weight(.medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("上个月").accessibilityIdentifier("calendarPreviousMonth")
            Button { store.today() } label: {
                Text("今天").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.foregroundStyle(NASStyle.ink)
                .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("calendarToday")
            Button { store.moveMonth(1) } label: {
                Image(systemName: "chevron.right").font(.callout.weight(.medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("下个月").accessibilityIdentifier("calendarNextMonth")
        }.buttonStyle(.plain)
    }

    private var displayModes: some View {
        HStack(spacing: 18) {
            ForEach(CalendarDisplayMode.allCases) { mode in
                Button { store.displayMode = mode } label: {
                    Text(mode.rawValue).font(.subheadline.weight(store.displayMode == mode ? .bold : .medium))
                        .foregroundStyle(store.displayMode == mode ? Color.primary : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(store.displayMode == mode ? NASStyle.signal : .clear).frame(height: 4)
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("calendarMode_" + mode.rawValue)
                    .accessibilityAddTraits(store.displayMode == mode ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("日历视图")
            .accessibilityIdentifier("calendarDisplayMode")
    }

    private var refreshButton: some View {
        Button { Task { await store.refresh() } } label: {
            Image(systemName: "arrow.clockwise").font(.subheadline)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.isLoading)
            .accessibilityLabel("刷新日历").accessibilityIdentifier("calendarRefresh")
    }

    private var calendarFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(store.visibleCalendars.count) 个日历")
                if store.visibleCalendars.contains(where: \.isLocal) { Text("· 含本机日历") }
                Spacer(minLength: 0)
                if store.isLoading { ProgressView().controlSize(.small) }
            }.font(.caption).foregroundStyle(.tertiary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { holidayMarkers; holidaySource }
                VStack(alignment: .leading, spacing: 2) { holidayMarkers; holidaySource }
            }
        }
    }

    @ViewBuilder private var holidayMarkers: some View {
        if ChinaHolidaySchedule.coverage(on: store.month) != nil {
            HStack(spacing: 5) {
                HolidayBadge(kind: .rest, fontSize: 8); Text("放假")
                HolidayBadge(kind: .work, fontSize: 8).padding(.leading, 7); Text("调休")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var holidaySource: some View {
        if let schedule = ChinaHolidaySchedule.coverage(on: store.month) {
            Link(destination: schedule.source) {
                Label("中国大陆放假安排", systemImage: "arrow.up.right")
                    .font(.caption2).frame(minHeight: 44).contentShape(Rectangle())
            }.foregroundStyle(.secondary)
        } else {
            Text("\(String(store.layout.calendar.component(.year, from: store.month)))年放假安排未收录")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                .accessibilityIdentifier("calendarHolidayCoverage")
        }
    }

    @ViewBuilder private func primaryContent(desktop: Bool, availableHeight: CGFloat) -> some View {
        if store.displayMode == .month { monthGrid(desktop: desktop, availableHeight: availableHeight) }
        else { monthAgenda.padding(.horizontal, desktop ? 28 : 20).padding(.bottom, 8) }
    }

    private func monthGrid(desktop: Bool, availableHeight: CGFloat) -> some View {
        let rows = store.layout.days(in: store.month).count / 7
        let cellHeight = desktop ? min(134, max(108, (availableHeight - 222) / CGFloat(rows))) : compactDayHeight
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, day in
                    Text(day).font(.caption2.weight(.medium))
                        .foregroundStyle(index >= 5 ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: 7), spacing: 0) {
                ForEach(store.layout.days(in: store.month), id: \.self) { date in
                    dayCell(date, desktop: desktop, height: cellHeight)
                }
            }
        }.padding(.horizontal, desktop ? 20 : 4).padding(.bottom, desktop ? 0 : 12)
            .accessibilityIdentifier("calendarMonthGrid")
    }

    private func dayCell(_ date: Date, desktop: Bool, height: CGFloat) -> some View {
        let events = store.events(on: date)
        let calendar = store.layout.calendar
        let selected = calendar.isDate(date, inSameDayAs: store.selectedDate)
        let today = calendar.isDateInToday(date)
        let currentMonth = calendar.isDate(date, equalTo: store.month, toGranularity: .month)
        let lunar = store.layout.lunarDate(on: date)
        let holiday = ChinaHolidaySchedule.day(on: date)
        let labelParts: [String?] = [date.formatted(.dateTime.month().day()), lunar.description, holiday?.description, "\(events.count)项日程"]
        let dayLabel = labelParts.compactMap { $0 }.joined(separator: "，")
        let heading = CalendarDayHeading(number: calendar.component(.day, from: date), lunar: lunar, holiday: holiday,
            desktop: desktop, selected: selected, today: today, currentMonth: currentMonth)
        return Group {
            if desktop {
                VStack(alignment: .leading, spacing: 2) {
                    Button { store.select(date) } label: {
                        heading.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(dayLabel)
                        .accessibilityIdentifier("calendarDay_" + store.layout.dayID(date))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    ForEach(events.prefix(2)) { event in
                        Button { open(event) } label: {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1).fill(color(for: event)).frame(width: 3, height: 14)
                                Text(event.title).font(.caption2.weight(.medium)).lineLimit(1)
                                    .foregroundStyle(currentMonth ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: AppPlatform.isMac ? 24 : 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(event.title + "，" + timeLabel(event, on: date))
                            .accessibilityHint("打开日程")
                            .accessibilityIdentifier("calendarGridEvent")
                    }
                    if events.count > 2 {
                        Button { store.select(date) } label: {
                            Text("+\(events.count - 2)").font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: AppPlatform.isMac ? 24 : 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("查看这一天的全部 \(events.count) 项日程")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
                .background {
                    Rectangle().fill(selected ? NASStyle.signal.opacity(0.11) : .clear)
                        .contentShape(Rectangle()).onTapGesture { store.select(date) }
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(NASStyle.outline).frame(height: 0.5).allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
            } else {
                Button { store.select(date) } label: {
                    VStack(spacing: 3) {
                        heading
                        HStack(spacing: 3) {
                            ForEach(events.prefix(3)) { event in Circle().fill(color(for: event)).frame(width: 4, height: 4) }
                        }.frame(maxWidth: .infinity).frame(height: 5)
                    }
                    .padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: height, alignment: .top)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(dayLabel)
                    .accessibilityIdentifier("calendarDay_" + store.layout.dayID(date))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func agenda(for date: Date) -> some View {
        let events = store.events(on: date)
        return VStack(alignment: .leading, spacing: 0) {
            selectedDayHeader(date, count: events.count)
            if let holiday = ChinaHolidaySchedule.day(on: date) {
                HStack(spacing: 7) {
                    HolidayBadge(kind: holiday.kind)
                    Text(holiday.description).font(.caption.weight(.medium))
                        .accessibilityIdentifier("calendarSelectedHoliday")
                }.foregroundStyle(.secondary).padding(.top, 12)
            }
            if events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这一天没有日程")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("calendarDayEmpty")
                    if store.visibleCalendars.isEmpty {
                        Button("显示全部日历") { store.showAll() }.font(.subheadline).frame(minHeight: 44)
                    }
                }.padding(.top, 22).padding(.bottom, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in eventRow(event, on: date) }
                }.padding(.top, 20)
            }
            Button { store.select(date); openNew() } label: {
                HStack {
                    Text("添加日程").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "plus").font(.body.weight(.semibold))
                }.padding(.horizontal, 16).frame(minHeight: 46)
                    .foregroundStyle(NASStyle.ink)
                    .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 8).disabled(!store.canCreate)
                .accessibilityIdentifier("calendarDayAdd")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedDayHeader(_ date: Date, count: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(String(format: "%02d", store.layout.calendar.component(.day, from: date)))
                .font(.system(size: 54, weight: .black, design: .rounded)).tracking(-2).monospacedDigit()
                .foregroundStyle(NASStyle.signal).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(date.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .accessibilityIdentifier("calendarSelectedDay")
                Text(store.layout.lunarDate(on: date).description)
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("calendarSelectedLunarDay")
                Text("\(count) 项").font(.caption2.weight(.semibold)).foregroundStyle(NASStyle.signal)
                    .accessibilityIdentifier("calendarDayCount")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NASStyle.ink, in: RoundedRectangle(cornerRadius: 16))
    }

    private var monthAgenda: some View {
        let dates = store.layout.days(in: store.month).filter {
            store.layout.calendar.isDate($0, equalTo: store.month, toGranularity: .month)
                && (!store.events(on: $0).isEmpty || ChinaHolidaySchedule.day(on: $0) != nil)
        }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if dates.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这个月没有日程").font(.subheadline).foregroundStyle(.secondary)
                    if store.visibleCalendars.isEmpty { Button("显示全部日历") { store.showAll() }.frame(minHeight: 44) }
                    else if store.canCreate { Button("添加日程") { openNew() }.frame(minHeight: 44) }
                }.padding(.vertical, 28)
            }
            ForEach(dates, id: \.self) { date in
                HStack(alignment: .center, spacing: 12) {
                    Text(String(store.layout.calendar.component(.day, from: date)))
                        .font(.system(size: 38, weight: .black, design: .rounded)).monospacedDigit()
                        .foregroundStyle(store.layout.calendar.isDateInToday(date) ? Theme.accent : Color.primary)
                        .frame(minWidth: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(date.formatted(.dateTime.month().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                            .font(.subheadline.weight(.medium))
                        Text(store.layout.lunarDate(on: date).description).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let holiday = ChinaHolidaySchedule.day(on: date) {
                        HolidayBadge(kind: holiday.kind).accessibilityLabel(holiday.description)
                    }
                }.padding(.top, 22).padding(.bottom, 14)
                if let holiday = ChinaHolidaySchedule.day(on: date) {
                    Text(holiday.description).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                }
                ForEach(store.events(on: date)) { event in eventRow(event, on: date) }
                Rectangle().fill(NASStyle.outline).frame(height: 0.5).padding(.top, 4)
            }
        }.accessibilityIdentifier("calendarAgendaList")
    }

    private func eventRow(_ event: CalendarOccurrence, on date: Date) -> some View {
        Button { open(event) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.isAllDay ? "全天" : event.start.formatted(.dateTime.hour().minute()))
                        .font(.caption.weight(.bold)).foregroundStyle(.primary)
                    if !event.isAllDay {
                        Text(event.end.formatted(.dateTime.hour().minute())).font(.caption2).foregroundStyle(.secondary)
                    }
                }.monospacedDigit().frame(width: eventTimeWidth, alignment: .leading)
                    .padding(.top, 14)
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(3)
                    HStack(spacing: 5) {
                        Circle().fill(color(for: event)).frame(width: 5, height: 5)
                        Text(store.source(for: event)?.title ?? "日历").lineLimit(1)
                        if event.hasRecurrence { Image(systemName: "repeat").accessibilityLabel("重复日程") }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if !store.layout.calendar.isDate(event.start, inSameDayAs: event.end), !event.isAllDay {
                        Text(timeLabel(event, on: date)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "mappin").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(for: event).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 3).padding(.vertical, 12)
                    }
            }.fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                .frame(minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("calendarEventRow")
            .accessibilityLabel(event.title + "，" + timeLabel(event, on: date))
    }
    private func timeLabel(_ event: CalendarOccurrence, on date: Date) -> String {
        if event.isAllDay { return "全天" }
        let start = event.start.formatted(.dateTime.hour().minute()), end = event.end.formatted(.dateTime.hour().minute())
        if store.layout.calendar.isDate(event.start, inSameDayAs: event.end) { return start + " – " + end }
        return event.start.formatted(.dateTime.month().day().hour().minute()) + " – " + event.end.formatted(.dateTime.month().day().hour().minute())
    }
    private func color(for event: CalendarOccurrence) -> Color { store.source(for: event)?.tint.color ?? Theme.accent }
    private func openNew() { presentation = store.presentation() }
    private func open(_ event: CalendarOccurrence) {
        presentation = store.presentation(for: event)
        if presentation == nil { Task { await store.refresh(keepingError: true) } }
    }
    private func openSettings() {
        let address = AppPlatform.isMac ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars" : UIApplication.openSettingsURLString
        if let url = URL(string: address) { UIApplication.shared.open(url) }
    }
}

private struct CalendarSourcesView: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.calendars) { calendar in
                        Toggle(isOn: Binding(get: { !store.hiddenCalendarIDs.contains(calendar.id) }, set: { store.setVisible($0, id: calendar.id) })) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(calendar.tint.color).frame(width: 32, height: 32)
                                    .background(calendar.tint.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(calendar.title).font(.subheadline.weight(.medium))
                                    Text(calendar.account + (calendar.isWritable ? "" : " · 只读")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.tint(Theme.accent).padding(.vertical, 3).accessibilityIdentifier("calendarToggle_" + calendar.title)
                    }
                    Button("显示全部日历") { store.showAll() }
                } footer: {
                    Text("隐藏日历会保留其中的日程。iCloud 等账户由系统同步；本机日历仅保存在当前设备。")
                }
            }.scrollContentBackground(.hidden).background(Theme.canvas)
                .navigationTitle("显示的日历").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("calendarSourcesDone") } }
        }
    }
}

private extension CalendarTint {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

private struct CalendarDayHeading: View {
    let number: Int
    let lunar: LunarCalendarDate
    let holiday: ChinaHolidayDay?
    let desktop: Bool
    let selected: Bool
    let today: Bool
    let currentMonth: Bool
    @ScaledMetric(relativeTo: .body) private var numberDiameter: CGFloat = 32

    var body: some View {
        let numberColor: Color = selected ? NASStyle.ink : today ? Theme.accent : currentMonth ? .primary : .secondary.opacity(0.45)
        let lunarColor: Color = currentMonth && lunar.festival != nil ? Theme.accent : .secondary
        VStack(alignment: desktop ? .leading : .center, spacing: 2) {
            Text(String(number))
                .font(.body.weight(selected || today ? .black : .medium)).monospacedDigit()
                .foregroundStyle(numberColor).lineLimit(1).minimumScaleFactor(0.65)
                .frame(width: min(numberDiameter, desktop ? 44 : 38), height: min(numberDiameter, desktop ? 44 : 38))
                .background(selected ? NASStyle.signal : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay { if today && !selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1) } }
                .overlay(alignment: .topTrailing) {
                    if let holiday { HolidayBadge(kind: holiday.kind, fontSize: 8).offset(x: 3, y: -1).opacity(currentMonth ? 1 : 0.5) }
                }
            Text(lunar.label)
                .font(.caption2.weight(lunar.festival == nil ? .regular : .medium))
                .foregroundStyle(lunarColor).opacity(currentMonth ? 1 : 0.55)
                .lineLimit(1).minimumScaleFactor(0.65)
                .padding(.leading, desktop ? 3 : 0)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: desktop ? .leading : .center)
    }
}
