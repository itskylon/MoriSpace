import SwiftUI
import EventKit
import Combine

@main
struct MoriPhotosApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var delegate
    @StateObject private var navigation = WorkspaceNavigation()
    @StateObject private var library = PhotoLibraryStore()
    @StateObject private var calendar = CalendarStore(widgetCache: .shared)
    @StateObject private var usage = UsageStore()
    @State private var showUsage = false
    @StateObject private var oneDrive: OneDriveSession
    @StateObject private var app: AppState
    @StateObject private var backup: PhotoBackupManager
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let state = AppState()
        let backups = PhotoBackupManager(app: state)
        _app = StateObject(wrappedValue: state)
        _backup = StateObject(wrappedValue: backups)
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        _oneDrive = StateObject(wrappedValue: OneDriveFixture.enabled ? OneDriveFixture.session() : OneDriveSession())
        #else
        _oneDrive = StateObject(wrappedValue: OneDriveSession())
        #endif
        BackupAppDelegate.manager = backups
    }
    var body: some Scene {
        WindowGroup {
            AdaptiveRootView(navigation: navigation)
            .tint(Theme.accent)
            .environmentObject(navigation)
            .environmentObject(library)
            .environmentObject(app)
            .environmentObject(backup)
            .environmentObject(calendar)
            .environmentObject(oneDrive)
            .environmentObject(usage)
            .onChange(of: oneDrive.account?.driveID) { previous, current in
                if let previous, previous != current { OneDriveMediaStore.shared.cancel(accountID: previous) }
            }
            .task { backup.foregroundChanged(scenePhase == .active) }
            .task { await calendar.refreshWidgetSnapshot() }
            .task { usage.reload() }
            .sheet(isPresented: $showUsage) {
                NavigationStack {
                    UsageView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { showUsage = false }
                                    .accessibilityIdentifier("dismissUsage")
                            }
                        }
                }
                .environmentObject(usage)
                .desktopSheet(width: 660, height: 680)
            }
            .onOpenURL { url in
                if UsageWidgetRoute.matchesConnection(url) {
                    showUsage = true
                    Task { await usage.connectPendingRemote() }
                    return
                }
                if UsageWidgetRoute.matches(url) {
                    usage.reload(); showUsage = true
                    return
                }
                guard let date = CalendarWidgetRoute.date(from: url) else { return }
                calendar.select(date); calendar.month = calendar.layout.month(containing: date)
                calendar.displayMode = .month
                navigation.paths[.calendar] = NavigationPath()
                navigation.selection = .calendar; navigation.phoneSelection = .calendar
            }
            .onReceive(calendar.$hiddenCalendarIDs.dropFirst()) { _ in Task { await calendar.refreshWidgetSnapshot() } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
                if scenePhase == .active { Task { await calendar.refreshWidgetSnapshot() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await calendar.refreshWidgetSnapshot() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    library.reload(); app.downloads.reloadIfNeeded()
                    usage.reload()
                    Task { await calendar.refreshWidgetSnapshot() }
                }
                backup.foregroundChanged(phase == .active)
            }
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { navigation.selection = .settings }.keyboardShortcut(",")
            }
            CommandMenu("前往") {
                ForEach(Array(WorkspacePage.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { navigation.selection = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
        #endif
    }
}

enum Theme {
    static let accent = NASStyle.accent
    static let canvas = NASStyle.canvas
}

struct EmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .regular))
                .foregroundStyle(NASStyle.accent).frame(width: 64, height: 64)
                .background(NASStyle.selection, in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 4).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 380).padding(.horizontal, 20).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.top, 2)
            Text(message).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("errorBanner")
    }
}
