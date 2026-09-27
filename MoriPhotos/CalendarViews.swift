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
            let desktop = wide && geometry.size.width >= 760
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
                            HStack(alignment: .top, spacing: 20) {
                                ScrollView {
                                    primaryContent(desktop: true, availableHeight: geometry.size.height)
                                    calendarSummary.padding(.horizontal, 16).padding(.vertical, 14)
                                }
                                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
                                .refreshable { await store.refresh() }
                                ScrollView {
                                    agenda(for: store.selectedDate).padding(20)
                                }
                                .frame(width: min(340, max(270, geometry.size.width * 0.29)))
                                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
                            }
                            .padding(.horizontal, 24).padding(.bottom, 20)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    primaryContent(desktop: false, availableHeight: geometry.size.height)
                                    if store.displayMode == .month {
                                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 20)
                                        agenda(for: store.selectedDate).padding(20)
                                    }
                                    calendarSummary.padding(.horizontal, 20).padding(.vertical, 16)
                                }
                            }.refreshable { await store.refresh() }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(desktop ? Theme.canvas : Color(uiColor: .systemBackground))
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
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 10) {
                Text("把日程放在手边").font(.title2.weight(.semibold))
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
                    }.padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
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
        VStack(alignment: .leading, spacing: desktop ? 14 : 10) {
            HStack(spacing: 12) {
                let parts = store.layout.calendar.dateComponents([.year, .month], from: store.month)
                Text("\(String(parts.year!))年 \(parts.month!)月")
                    .font(.system(size: desktop ? 26 : 23, weight: .semibold))
                    .tracking(-0.5).accessibilityIdentifier("calendarMonthTitle")
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    Button { store.moveMonth(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.accessibilityLabel("上个月").accessibilityIdentifier("calendarPreviousMonth")
                    Button("今天") { store.today() }
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 9).frame(height: 36)
                        .accessibilityIdentifier("calendarToday")
                    Button { store.moveMonth(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.accessibilityLabel("下个月").accessibilityIdentifier("calendarNextMonth")
                }.buttonStyle(.plain)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Picker("日历视图", selection: $store.displayMode) {
                    ForEach(CalendarDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("calendarDisplayMode")
                Spacer()
                if desktop { holidayLegend }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.isLoading)
                    .accessibilityLabel("刷新日历").accessibilityIdentifier("calendarRefresh")
            }
            if !desktop { holidayLegend }
        }.padding(.horizontal, desktop ? 24 : 20).padding(.top, desktop ? 20 : 12).padding(.bottom, 16)
    }

    private var holidayLegend: some View {
        HStack(spacing: 5) {
            if let schedule = ChinaHolidaySchedule.coverage(on: store.month) {
                HolidayBadge(kind: .rest, fontSize: 8); Text("放假")
                HolidayBadge(kind: .work, fontSize: 8).padding(.leading, 5); Text("调休")
                Spacer(minLength: 4)
                Link(destination: schedule.source) {
                    HStack(spacing: 3) { Text("中国大陆放假安排"); Image(systemName: "arrow.up.right").font(.system(size: 8)) }
                }.foregroundStyle(.secondary)
            } else {
                Text("\(String(store.layout.calendar.component(.year, from: store.month)))年放假安排未收录")
                    .accessibilityIdentifier("calendarHolidayCoverage")
                Spacer(minLength: 0)
            }
        }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var calendarSummary: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5)
            Text("\(store.visibleCalendars.count) 个日历")
            if store.visibleCalendars.contains(where: \.isLocal) { Text("· 含本机日历") }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func primaryContent(desktop: Bool, availableHeight: CGFloat) -> some View {
        if store.displayMode == .month { monthGrid(desktop: desktop, availableHeight: availableHeight) }
        else { monthAgenda.padding(.horizontal, 20).padding(.bottom, 8) }
    }

    private func monthGrid(desktop: Bool, availableHeight: CGFloat) -> some View {
        let rows = store.layout.days(in: store.month).count / 7
        let cellHeight = desktop ? min(144, max(120, (availableHeight - 224) / CGFloat(rows))) : 65.0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, day in
                    Text(day).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(index >= 5 ? Theme.accent.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, desktop ? 14 : 8)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(store.layout.days(in: store.month), id: \.self) { date in
                    dayCell(date, desktop: desktop, height: cellHeight)
                }
            }
        }.padding(.horizontal, desktop ? 8 : 12).padding(.bottom, desktop ? 0 : 12)
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
        let accessibilityLabel = labelParts.compactMap { $0 }.joined(separator: "，")
        return VStack(spacing: desktop ? 3 : 2) {
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
        .padding(.horizontal, desktop ? 5 : 0).padding(.vertical, 4)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(selected ? Theme.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: desktop ? 6 : 10))
        .overlay(alignment: .top) { if desktop { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) } }
        .contentShape(Rectangle()).onTapGesture { store.select(date) }
    }

    private func agenda(for date: Date) -> some View {
        let events = store.events(on: date)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("calendarSelectedDay")
                Spacer(minLength: 8)
                Text("\(events.count) 项").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("calendarDayCount")
            }
            Text(store.layout.lunarDate(on: date).description)
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 16)
                .accessibilityIdentifier("calendarSelectedLunarDay")
            if let holiday = ChinaHolidaySchedule.day(on: date) {
                HStack(spacing: 7) {
                    HolidayBadge(kind: holiday.kind)
                    Text(holiday.description).font(.system(size: 12, weight: .medium))
                        .accessibilityIdentifier("calendarSelectedHoliday")
                    Spacer(minLength: 0)
                }.padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
            if events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: store.visibleCalendars.isEmpty ? "eye.slash" : "calendar.badge.checkmark")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7))
                    Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这一天没有日程")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("calendarDayEmpty")
                    if store.visibleCalendars.isEmpty { Button("显示全部日历") { store.showAll() }.font(.subheadline) }
                }.padding(.vertical, 18)
            } else {
                ForEach(events) { event in
                    eventRow(event, on: date)
                    if event.id != events.last?.id { Divider().opacity(0.6) }
                }
            }
            Button { store.select(date); openNew() } label: {
                Label("添加日程", systemImage: "plus").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 16).disabled(!store.canCreate)
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
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                    Text(store.visibleCalendars.isEmpty ? "已隐藏全部日历" : "这个月没有日程").font(.subheadline).foregroundStyle(.secondary)
                    if store.visibleCalendars.isEmpty { Button("显示全部日历") { store.showAll() } }
                    else if store.canCreate { Button("添加日程") { openNew() } }
                }.padding(.vertical, 28)
            }
            ForEach(dates, id: \.self) { date in
                HStack(alignment: .center, spacing: 12) {
                    Text(String(store.layout.calendar.component(.day, from: date)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(store.layout.calendar.isDateInToday(date) ? Theme.accent : Color.primary)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(date.formatted(.dateTime.month().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                            .font(.system(size: 12, weight: .medium))
                        Text(store.layout.lunarDate(on: date).description).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let holiday = ChinaHolidaySchedule.day(on: date) {
                        HolidayBadge(kind: holiday.kind)
                            .accessibilityLabel(holiday.description)
                    }
                }.padding(.top, 20).padding(.bottom, 6)
                if let holiday = ChinaHolidaySchedule.day(on: date) {
                    Text(holiday.description).font(.caption).foregroundStyle(.secondary).padding(.leading, 50).padding(.bottom, 8)
                }
                ForEach(store.events(on: date)) { event in eventRow(event, on: date) }
                Divider().opacity(0.6)
            }
        }.accessibilityIdentifier("calendarAgendaList")
    }

    private func eventRow(_ event: CalendarOccurrence, on date: Date) -> some View {
        Button { open(event) } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.isAllDay ? "全天" : event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    if !event.isAllDay {
                        Text(event.end.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.monospacedDigit().frame(width: 48, alignment: .leading)
                RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(store.source(for: event)?.title ?? "日历").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if !store.layout.calendar.isDate(event.start, inSameDayAs: event.end), !event.isAllDay {
                        Text(timeLabel(event, on: date)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "mappin").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if event.hasRecurrence {
                    Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel("重复日程")
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 13).contentShape(Rectangle())
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

    var body: some View {
        let numberColor: Color = today ? Color(uiColor: .systemBackground) : selected ? Theme.accent : currentMonth ? .primary : .secondary.opacity(0.5)
        let lunarColor: Color = currentMonth && lunar.festival != nil ? Theme.accent : .secondary
        VStack(spacing: 1) {
            Text(String(number))
                .font(.system(size: desktop ? 14 : 16, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(numberColor)
                .frame(width: desktop ? 27 : 32, height: desktop ? 27 : 32)
                .background(today ? Theme.accent : .clear, in: Circle())
                .overlay { if selected && !today { Circle().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1) } }
                .overlay(alignment: .topTrailing) {
                    if let holiday { HolidayBadge(kind: holiday.kind, fontSize: 8).offset(x: 6, y: -1).opacity(currentMonth ? 1 : 0.5) }
                }
            Text(lunar.label)
                .font(.system(size: desktop ? 10 : 10.5, weight: lunar.festival == nil ? .regular : .medium))
                .foregroundStyle(lunarColor).opacity(currentMonth ? 1 : 0.6)
                .lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
        }.frame(maxWidth: .infinity, minHeight: desktop ? 44 : 49)
    }
}
