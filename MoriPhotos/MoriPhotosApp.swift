import SwiftUI
import EventKit
import Combine

@main
struct MoriPhotosApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var delegate
    @StateObject private var navigation = WorkspaceNavigation()
    @StateObject private var library = PhotoLibraryStore()
    @StateObject private var calendar = CalendarStore(widgetCache: .shared)
    @StateObject private var app: AppState
    @StateObject private var backup: PhotoBackupManager
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let state = AppState()
        let backups = PhotoBackupManager(app: state)
        _app = StateObject(wrappedValue: state)
        _backup = StateObject(wrappedValue: backups)
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
            .task { backup.foregroundChanged(scenePhase == .active) }
            .task { await calendar.refreshWidgetSnapshot() }
            .onOpenURL { url in
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
    static let canvas = Color(uiColor: .systemGroupedBackground)
}

struct EmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(Theme.accent.opacity(0.09)).frame(width: 100, height: 100).rotationEffect(.degrees(-7))
                Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
            }
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.vertical, 40)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("errorBanner")
    }
}
