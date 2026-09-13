import EventKit
import SwiftUI
import WidgetKit

extension CalendarAccess {
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess: self = .full
        case .notDetermined: self = .notDetermined
        case .writeOnly: self = .writeOnly
        case .restricted: self = .restricted
        default: self = .denied
        }
    }
}

@MainActor protocol CalendarProviding {
    var access: CalendarAccess { get }
    func requestAccess() async throws
    func snapshot(in interval: DateInterval) async throws -> CalendarSnapshot
    func presentation(for occurrence: CalendarOccurrence?, on date: Date, preferredCalendarID: String?) throws -> CalendarPresentation
}

enum CalendarFailure: LocalizedError {
    case noAccess, noWritableCalendar, eventMissing, previewOnly
    var errorDescription: String? {
        switch self {
        case .noAccess: "日历权限已改变，请重新检查系统设置。"
        case .noWritableCalendar: "没有可写入的日历。请先在苹果日历中添加日历账户或创建日历。"
        case .eventMissing: "这条日程已移动或删除，日历已刷新，请重新选择。"
        case .previewOnly: "这是隔离的界面测试数据，不能写入系统日历。"
        }
    }
}

// Query on an actor with its own EventKit store. Only value snapshots cross to the UI;
// the system editor always receives events belonging to its separate main-thread store.
actor CalendarQuery {
    private var store: EKEventStore?
    func snapshot(in interval: DateInterval, calendarIDs: Set<String>? = nil) throws -> CalendarSnapshot {
        guard CalendarAccess(EKEventStore.authorizationStatus(for: .event)) == .full else { throw CalendarFailure.noAccess }
        let store = store ?? EKEventStore()
        self.store = store
        store.reset()
        let calendars = store.calendars(for: .event).filter { calendarIDs?.contains($0.calendarIdentifier) ?? true }
        let sources = calendars.map { source -> CalendarSourceItem in
            var r: CGFloat = 0.2, g: CGFloat = 0.6, b: CGFloat = 0.4, a: CGFloat = 1
            if let color = source.cgColor { UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a) }
            return CalendarSourceItem(id: source.calendarIdentifier, title: source.title, account: source.source.title,
                isWritable: source.allowsContentModifications, isLocal: source.type == .local,
                tint: CalendarTint(red: r, green: g, blue: b))
        }.sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let events = calendars.isEmpty ? [] : store.events(matching: predicate).compactMap { event -> CalendarOccurrence? in
            guard let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate,
                  let calendar = event.calendar else { return nil }
            return CalendarOccurrence(eventIdentifier: identifier, calendarItemIdentifier: event.calendarItemIdentifier,
                calendarID: calendar.calendarIdentifier, title: event.title?.isEmpty == false ? event.title : "无标题日程",
                start: start, end: end, isAllDay: event.isAllDay, location: event.location ?? "", hasRecurrence: event.hasRecurrenceRules)
        }
        return CalendarSnapshot(calendars: sources, events: events)
    }
}

@MainActor final class SystemCalendarProvider: CalendarProviding {
    let eventStore = EKEventStore()
    private let query = CalendarQuery()
    private var testingCalendarID: String?
    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--calendar-live-fixture") {
            testingCalendarID = try? CalendarLiveFixture.prepare(in: eventStore)
        }
        #endif
    }
    var access: CalendarAccess { CalendarAccess(EKEventStore.authorizationStatus(for: .event)) }
    func requestAccess() async throws { _ = try await eventStore.requestFullAccessToEvents() }
    func snapshot(in interval: DateInterval) async throws -> CalendarSnapshot {
        try await query.snapshot(in: interval, calendarIDs: testingCalendarID.map { Set([$0]) })
    }

    func presentation(for occurrence: CalendarOccurrence?, on date: Date, preferredCalendarID: String?) throws -> CalendarPresentation {
        guard access == .full else { throw CalendarFailure.noAccess }
        eventStore.reset()
        if let occurrence {
            guard let calendar = eventStore.calendar(withIdentifier: occurrence.calendarID) else { throw CalendarFailure.eventMissing }
            // event(withIdentifier:) returns the FIRST recurrence. Resolve the selected occurrence instead.
            let predicate = eventStore.predicateForEvents(withStart: occurrence.start.addingTimeInterval(-1),
                end: occurrence.start.addingTimeInterval(1), calendars: [calendar])
            guard let event = eventStore.events(matching: predicate).first(where: {
                $0.calendarItemIdentifier == occurrence.calendarItemIdentifier && $0.startDate == occurrence.start
            }) else { throw CalendarFailure.eventMissing }
            return CalendarPresentation(store: eventStore, event: event, isNew: false)
        }
        let preferred = (testingCalendarID ?? preferredCalendarID).flatMap { eventStore.calendar(withIdentifier: $0) }
        let systemDefault = eventStore.defaultCalendarForNewEvents
        let destination = [preferred, systemDefault].compactMap { $0 }.first(where: \.allowsContentModifications)
            ?? eventStore.calendars(for: .event).first(where: \.allowsContentModifications)
        guard let destination, destination.allowsContentModifications else { throw CalendarFailure.noWritableCalendar }
        let event = EKEvent(eventStore: eventStore)
        event.calendar = destination
        event.startDate = CalendarLayout().defaultStart(on: date)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.timeZone = .current
        return CalendarPresentation(store: eventStore, event: event, isNew: true)
    }
}

@MainActor final class CalendarStore: ObservableObject {
    @Published private(set) var access: CalendarAccess
    @Published private(set) var calendars: [CalendarSourceItem] = []
    @Published private(set) var events: [CalendarOccurrence] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var hiddenCalendarIDs: Set<String>
    @Published var month: Date
    @Published var selectedDate: Date
    @Published var error: String?
    @Published var displayMode = CalendarDisplayMode.month
    private let provider: CalendarProviding
    private let defaults: UserDefaults
    private var generation = 0
    private var widgetGeneration = 0
    private let widgetCache: CalendarWidgetCache?
    var layout: CalendarLayout { CalendarLayout() }

    init(provider: CalendarProviding? = nil, defaults: UserDefaults = .standard, now: Date = Date(), widgetCache: CalendarWidgetCache? = nil) {
        let source = provider ?? Self.makeProvider()
        self.provider = source; self.defaults = defaults; access = source.access
        month = CalendarLayout().month(containing: now); selectedDate = CalendarLayout().day(containing: now)
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: "calendar.hiddenCalendarIDs") ?? [])
        var cache = widgetCache
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--empty-connection-fixture") && !ProcessInfo.processInfo.arguments.contains("--widget-fixture") { cache = nil }
        #endif
        self.widgetCache = cache
    }
    private static func makeProvider() -> CalendarProviding {
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if ProcessInfo.processInfo.arguments.contains("--calendar-fixture") { return CalendarPreviewProvider() }
        #endif
        return SystemCalendarProvider()
    }
    var visibleEvents: [CalendarOccurrence] { events.filter { !hiddenCalendarIDs.contains($0.calendarID) } }
    var visibleCalendars: [CalendarSourceItem] { calendars.filter { !hiddenCalendarIDs.contains($0.id) } }
    var canCreate: Bool { access == .full && calendars.contains(where: \.isWritable) }
    func source(for event: CalendarOccurrence) -> CalendarSourceItem? { calendars.first { $0.id == event.calendarID } }
    func events(on date: Date) -> [CalendarOccurrence] { layout.events(visibleEvents, on: date) }
    func select(_ date: Date) { selectedDate = layout.day(containing: date) }
    func moveMonth(_ offset: Int) { month = layout.addingMonths(offset, to: month); selectedDate = month }
    func today() { selectedDate = layout.day(containing: Date()); month = layout.month(containing: selectedDate) }
    func setVisible(_ visible: Bool, id: String) {
        if visible { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
        defaults.set(Array(hiddenCalendarIDs).sorted(), forKey: "calendar.hiddenCalendarIDs")
    }
    func showAll() {
        hiddenCalendarIDs.removeAll(); defaults.removeObject(forKey: "calendar.hiddenCalendarIDs")
    }
    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true; error = nil
        defer { isRequestingAccess = false }
        do { try await provider.requestAccess() } catch { self.error = error.localizedDescription }
        await refresh()
        await refreshWidgetSnapshot()
    }
    func refreshWidgetSnapshot(now: Date = Date()) async {
        guard let widgetCache else { return }
        widgetGeneration += 1
        let request = widgetGeneration
        let snapshot: CalendarWidgetSnapshot
        if provider.access != .full {
            snapshot = .empty(.permissionRequired, now: now)
        } else {
            do {
                let interval = DateInterval(start: layout.day(containing: now), end: layout.addingDays(7, to: layout.day(containing: now)))
                let data = try await provider.snapshot(in: interval)
                guard request == widgetGeneration, !Task.isCancelled else { return }
                if provider.access != .full {
                    snapshot = .empty(.permissionRequired, now: now)
                } else {
                    let events = data.events.filter { !hiddenCalendarIDs.contains($0.calendarID) && ($0.end > now || $0.start >= now) }
                        .sorted { $0.start < $1.start }.prefix(512).map { event in
                            let color = data.calendars.first { $0.id == event.calendarID }?.tint ?? CalendarTint()
                            return CalendarWidgetEvent(id: event.id, title: String(event.title.prefix(200)), start: event.start, end: event.end,
                                isAllDay: event.isAllDay, red: color.red, green: color.green, blue: color.blue)
                        }
                    snapshot = CalendarWidgetSnapshot(status: .ready, updatedAt: now, validUntil: now.addingTimeInterval(24 * 3600), events: events)
                }
            } catch {
                guard request == widgetGeneration, !Task.isCancelled else { return }
                snapshot = .empty(provider.access == .full ? .unavailable : .permissionRequired, now: now)
            }
        }
        guard request == widgetGeneration, !Task.isCancelled else { return }
        do {
            try widgetCache.write(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: CalendarWidgetConstants.kind)
        } catch {
            // Failed writes must not leave a previous, potentially private snapshot behind.
            if let url = widgetCache.fileURL { try? FileManager.default.removeItem(at: url) }
            WidgetCenter.shared.reloadTimelines(ofKind: CalendarWidgetConstants.kind)
        }
    }
    func refresh(keepingError: Bool = false) async {
        generation += 1
        let request = generation
        access = provider.access
        guard access == .full else { events = []; calendars = []; isLoading = false; return }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let snapshot = try await provider.snapshot(in: layout.visibleInterval(for: month))
            guard generation == request, !Task.isCancelled else { return }
            access = provider.access
            guard access == .full else { events = []; calendars = []; return }
            calendars = snapshot.calendars; events = snapshot.events
            if !keepingError { error = nil }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            access = provider.access; events = []
            if access != .full { calendars = [] }
            self.error = access == .full ? error.localizedDescription : nil
        }
    }
    func presentation(for event: CalendarOccurrence? = nil) -> CalendarPresentation? {
        error = nil
        let preferred = visibleCalendars.filter(\.isWritable)
        do { return try provider.presentation(for: event, on: selectedDate, preferredCalendarID: preferred.count == 1 ? preferred[0].id : nil) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func didSave(start: Date, calendarID: String) {
        select(start); month = layout.month(containing: start); setVisible(true, id: calendarID)
    }
}

enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case month = "月历", agenda = "日程"
    var id: String { rawValue }
}
