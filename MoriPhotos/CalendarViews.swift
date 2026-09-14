import SwiftUI
import EventKit
import Combine

struct CalendarHomeView: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.wideWorkspace) private var wide
    @Environment(\.scenePhase) private var phase
    @State private var presentation: CalendarPresentation?
    @State private var showingCalendars = false
    var isActive = true

    var body: some View {
        GeometryReader { geometry in
            let desktop = wide && geometry.size.width >= 700
            Group {
                if store.access != .full { permissionView }
                else {
                    ScrollView {
                        VStack(spacing: 0) {
                            controls
                            if let error = store.error { ErrorBanner(message: error).padding(.horizontal, 16).padding(.bottom, 12) }
                            if store.calendars.isEmpty {
                                if store.isLoading { ProgressView("正在读取日历…").padding(40) }
                                else { ContentUnavailableView("没有可用日历", systemImage: "calendar", description: Text("请先在苹果日历中添加账户或创建日历，再回来刷新。")) }
                            } else if desktop {
                                HStack(alignment: .top, spacing: 0) {
                                    primaryContent(desktop: true).frame(maxWidth: .infinity)
                                    agenda(for: store.selectedDate)
                                        .padding(20).frame(width: 280, alignment: .topLeading)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                        .background(Color(uiColor: .secondarySystemBackground).opacity(0.4))
                                        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5) }
                                }
                            } else {
                                primaryContent(desktop: false)
                                if store.displayMode == .month {
                                    Divider()
                                    agenda(for: store.selectedDate).padding(20)
                                }
                            }
                            if !store.calendars.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "calendar")
                                    Text("\(store.visibleCalendars.count) 个日历")
                                    if store.visibleCalendars.contains(where: \.isLocal) { Text("· 含本机日历") }
                                    Spacer()
                                    if store.isLoading { ProgressView().controlSize(.small) }
                                }.font(.caption).foregroundStyle(.secondary).padding(16)
                            }
                        }
                    }.refreshable { await store.refresh() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
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
        VStack(spacing: 18) {
            Image(systemName: "calendar").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
            Text("使用系统日历").font(.title2.weight(.semibold))
            Text(store.access.message).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
            if store.access == .notDetermined || store.access == .writeOnly {
                Button { Task { await store.requestAccess() } } label: {
                    if store.isRequestingAccess { ProgressView() } else { Text("允许访问日历") }
                }.buttonStyle(.borderedProminent).disabled(store.isRequestingAccess).accessibilityIdentifier("calendarRequestAccess")
            } else if store.access == .denied {
                Button("打开系统设置", action: openSettings).buttonStyle(.borderedProminent).accessibilityIdentifier("calendarOpenSettings")
            }
            Text("选择 iCloud 日历可由系统同步到其他设备。仅存于本机的日历不会跨设备同步。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(maxWidth: 460).accessibilityIdentifier("calendarPermissionView")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                let parts = store.layout.calendar.dateComponents([.year, .month], from: store.month)
                Text("\(String(parts.year!))年 \(parts.month!)月").font(.title2.weight(.semibold)).accessibilityIdentifier("calendarMonthTitle")
                Spacer(minLength: 4)
                Button { store.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 34) }
                    .accessibilityLabel("上个月").accessibilityIdentifier("calendarPreviousMonth")
                Button("今天") { store.today() }.buttonStyle(.bordered).accessibilityIdentifier("calendarToday")
                Button { store.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 34) }
                    .accessibilityLabel("下个月").accessibilityIdentifier("calendarNextMonth")
            }.buttonStyle(.plain)
            HStack {
                Picker("日历视图", selection: $store.displayMode) {
                    ForEach(CalendarDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 180).accessibilityIdentifier("calendarDisplayMode")
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.isLoading).accessibilityLabel("刷新日历").accessibilityIdentifier("calendarRefresh")
            }
            HStack(spacing: 5) {
                if let schedule = ChinaHolidaySchedule.coverage(on: store.month) {
                    Text("中国大陆")
                    HolidayBadge(kind: .rest, fontSize: 8); Text("放假")
                    HolidayBadge(kind: .work, fontSize: 8); Text("调休上班")
                    Spacer(minLength: 4)
                    Link("官方安排", destination: schedule.source)
                } else {
                    Text("\(String(store.layout.calendar.component(.year, from: store.month)))年放假安排未收录")
                        .accessibilityIdentifier("calendarHolidayCoverage")
                    Spacer()
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(16)
    }

    @ViewBuilder private func primaryContent(desktop: Bool) -> some View {
        if store.displayMode == .month { monthGrid(desktop: desktop) }
        else { monthAgenda.padding(.horizontal, 20) }
    }

    private func monthGrid(desktop: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(store.layout.days(in: store.month), id: \.self) { date in
                    dayCell(date, desktop: desktop)
                }
            }
        }.padding(.horizontal, desktop ? 0 : 8).padding(.bottom, desktop ? 0 : 12)
            .accessibilityIdentifier("calendarMonthGrid")
    }

    private func dayCell(_ date: Date, desktop: Bool) -> some View {
        let events = store.events(on: date)
        let calendar = store.layout.calendar
        let selected = calendar.isDate(date, inSameDayAs: store.selectedDate)
        let today = calendar.isDateInToday(date)
        let currentMonth = calendar.isDate(date, equalTo: store.month, toGranularity: .month)
        let lunar = store.layout.lunarDate(on: date)
        let holiday = ChinaHolidaySchedule.day(on: date)
        let labelParts: [String?] = [date.formatted(.dateTime.month().day()), lunar.description, holiday?.description, "\(events.count)项日程"]
        let accessibilityLabel = labelParts.compactMap { $0 }.joined(separator: "，")
        return VStack(spacing: desktop ? 4 : 2) {
            Button { store.select(date) } label: {
                CalendarDayHeading(number: calendar.component(.day, from: date), lunar: lunar, holiday: holiday,
                    desktop: desktop, selected: selected, today: today, currentMonth: currentMonth)
            }.buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("calendarDay_" + store.layout.dayID(date))
                .accessibilityAddTraits(selected ? .isSelected : [])
            if desktop {
                ForEach(events.prefix(2)) { event in
                    Button { open(event) } label: {
                        Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.vertical, 3)
                            .foregroundStyle(color(for: event)).background(color(for: event).opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                    }.buttonStyle(.plain).accessibilityLabel(event.title)
                }
                if events.count > 2 {
                    Button("还有 \(events.count - 2) 项") { store.select(date) }.font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 3) { ForEach(events.prefix(3)) { event in Circle().fill(color(for: event)).frame(width: 4, height: 4) } }
                    .frame(height: 5).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, desktop ? 4 : 0).padding(.vertical, 4)
        .frame(height: desktop ? 124 : 65, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(selected ? Theme.accent.opacity(0.08) : .clear)
        .overlay(alignment: .top) { if desktop { Divider() } }
        .overlay(alignment: .trailing) { if desktop { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5) } }
        .contentShape(Rectangle()).onTapGesture { store.select(date) }
    }

    private func agenda(for date: Date) -> some View {
        let events = store.events(on: date)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(date.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN")))).font(.headline).accessibilityIdentifier("calendarSelectedDay")
                Spacer()
                Text("\(events.count) 项").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("calendarDayCount")
            }
            Text(store.layout.lunarDate(on: date).description)
                .font(.caption).foregroundStyle(.secondary).padding(.top, 5).padding(.bottom, 10)
                .accessibilityIdentifier("calendarSelectedLunarDay")
            if let holiday = ChinaHolidaySchedule.day(on: date) {
                HStack(spacing: 6) {
                    HolidayBadge(kind: holiday.kind)
                    Text(holiday.description).font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("calendarSelectedHoliday")
                }.padding(.bottom, 12)
            }
            if events.isEmpty {
                Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这一天没有日程")
                    .foregroundStyle(.secondary).padding(.vertical, 24).accessibilityIdentifier("calendarDayEmpty")
                if store.visibleCalendars.isEmpty { Button("显示全部日历") { store.showAll() } }
            } else {
                ForEach(events) { event in eventRow(event, on: date); Divider() }
            }
            Button { store.select(date); openNew() } label: { Label("添加日程", systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 20).disabled(!store.canCreate)
                .accessibilityIdentifier("calendarDayAdd")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monthAgenda: some View {
        let dates = store.layout.days(in: store.month).filter {
            store.layout.calendar.isDate($0, equalTo: store.month, toGranularity: .month)
                && (!store.events(on: $0).isEmpty || ChinaHolidaySchedule.day(on: $0) != nil)
        }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if dates.isEmpty {
                Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这个月没有日程").foregroundStyle(.secondary).padding(.vertical, 32)
                if store.visibleCalendars.isEmpty { Button("显示全部日历") { store.showAll() } }
            }
            ForEach(dates, id: \.self) { date in
                Text(date.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN")))).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary).padding(.top, 20).padding(.bottom, 4)
                Text(store.layout.lunarDate(on: date).description)
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                if let holiday = ChinaHolidaySchedule.day(on: date) {
                    HStack(spacing: 6) { HolidayBadge(kind: holiday.kind); Text(holiday.description).font(.subheadline) }
                        .padding(.bottom, 8)
                }
                ForEach(store.events(on: date)) { event in eventRow(event, on: date) }
                Divider()
            }
        }.accessibilityIdentifier("calendarAgendaList")
    }

    private func eventRow(_ event: CalendarOccurrence, on date: Date) -> some View {
        Button { open(event) } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(timeLabel(event, on: date) + " · " + (store.source(for: event)?.title ?? "日历")).font(.caption).foregroundStyle(.secondary)
                    if !event.location.isEmpty { Label(event.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if event.hasRecurrence { Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary).accessibilityLabel("重复日程") }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("calendarEventRow").accessibilityLabel(event.title + "，" + timeLabel(event, on: date))
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
                                Circle().fill(calendar.tint.color).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(calendar.title)
                                    Text(calendar.account + (calendar.isWritable ? "" : " · 只读")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.accessibilityIdentifier("calendarToggle_" + calendar.title)
                    }
                    Button("显示全部日历") { store.showAll() }
                } footer: {
                    Text("这里切换日历的显示，不会删除日程。要跨设备同步，请把日程保存到 iCloud 等支持同步的账户，并在各设备开启该账户的日历。本机日历不会跨设备同步。")
                }
            }.navigationTitle("显示的日历").navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        let numberColor: Color = today ? Color(uiColor: .systemBackground) : selected ? Theme.accent : currentMonth ? .primary : .secondary
        let lunarColor: Color = currentMonth && lunar.festival != nil ? Theme.accent : .secondary
        VStack(spacing: 1) {
            Text(String(number))
                .font(.system(size: desktop ? 13 : 16, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(numberColor)
                .frame(width: desktop ? 28 : 34, height: desktop ? 28 : 34)
                .background(today ? Theme.accent : .clear, in: Circle())
                .overlay { if selected && !today { Circle().strokeBorder(Theme.accent, lineWidth: 1) } }
                .overlay(alignment: .topTrailing) {
                    if let holiday { HolidayBadge(kind: holiday.kind, fontSize: 8).offset(x: 6, y: -1).opacity(currentMonth ? 1 : 0.5) }
                }
            Text(lunar.label)
                .font(.system(size: 11, weight: lunar.festival == nil ? .regular : .medium))
                .foregroundStyle(lunarColor).opacity(currentMonth ? 1 : 0.6)
                .lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
        }.frame(maxWidth: .infinity, minHeight: desktop ? 44 : 49)
    }
}
