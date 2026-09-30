import SwiftUI
import UIKit

enum AppPlatform {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    static var libraryName: String { isMac ? "Mac 照片图库" : "本机照片" }
    static var downloadTitle: String { isMac ? "下载到 Mac" : "下载到本机" }
    static func openPhotoSettings() {
        let address = isMac ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos" : UIApplication.openSettingsURLString
        if let url = URL(string: address) { UIApplication.shared.open(url) }
    }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case local, photos, files, downloads, monitor, backup, settings, calendar, oneDrive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: AppPlatform.libraryName
        case .photos: "群晖照片"
        case .files: "群晖文件"
        case .downloads: "下载"
        case .monitor: "运行状态"
        case .backup: "照片备份"
        case .settings: "设置"
        case .calendar: "日历"
        case .oneDrive: "OneDrive"
        }
    }
    var symbol: String {
        switch self {
        case .local: "photo.on.rectangle"
        case .photos: "photo.stack"
        case .files: "folder"
        case .downloads: "arrow.down.circle"
        case .monitor: "waveform.path.ecg"
        case .backup: "icloud.and.arrow.up"
        case .settings: "gearshape"
        case .calendar: "calendar"
        case .oneDrive: "cloud"
        }
    }
}

@MainActor final class WorkspaceNavigation: ObservableObject {
    @Published var selection: WorkspacePage = .photos
    @Published var phoneSelection: WorkspacePage = .local
    @Published var paths: [WorkspacePage: NavigationPath] = [:]
}

struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var navigation: WorkspaceNavigation
    var body: some View {
        if AppPlatform.isMac || sizeClass == .regular {
            DesktopWorkspaceView(navigation: navigation)
        } else {
            TabView(selection: $navigation.phoneSelection) {
                NavigationStack { LocalLibraryView() }.tabItem { Label("照片", systemImage: "square.grid.2x2") }.tag(WorkspacePage.local)
                StorageHomeView(isActive: navigation.phoneSelection == .photos).tabItem { Label("存储", systemImage: "externaldrive") }.tag(WorkspacePage.photos)
                NavigationStack { CalendarHomeView(isActive: navigation.phoneSelection == .calendar) }.tabItem { Label("日历", systemImage: "calendar") }.tag(WorkspacePage.calendar)
                NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(WorkspacePage.settings)
            }
            .toolbarBackground(.regularMaterial, for: .tabBar)
        }
    }
}

struct DesktopWorkspaceView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var navigation: WorkspaceNavigation
    @State private var visited: Set<WorkspacePage> = [.photos]
    @State private var visibility: NavigationSplitViewVisibility = .all
    @FocusState private var sidebarFocus: WorkspacePage?
    @State private var hoveredPage: WorkspacePage?
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 21, weight: .medium)).foregroundStyle(NASStyle.accent)
                        .frame(width: 40, height: 40).background(NASStyle.selection, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("森空间").font(.headline).foregroundStyle(.primary)
                        Text("Mori Space").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        sidebarGroup("资料库", pages: [.local, .photos, .files, .oneDrive])
                        sidebarGroup("工具", pages: [.calendar, .downloads, .monitor, .backup])
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden)
                    .accessibilityIdentifier("workspaceSidebar")
                row(.settings).padding(12)
            }
            .background(NASStyle.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 270)
        } detail: {
            NavigationStack(path: path) {
                ZStack {
                    ForEach(WorkspacePage.allCases.filter { visited.contains($0) || $0 == navigation.selection }) { page in
                        content(page)
                            .opacity(navigation.selection == page ? 1 : 0)
                            .allowsHitTesting(navigation.selection == page)
                            .disabled(navigation.selection != page)
                            .accessibilityHidden(navigation.selection != page)
                            .zIndex(navigation.selection == page ? 1 : 0)
                    }
                }
                .navigationTitle(navigation.selection.title).navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: NASFile.self) { folder in
                    if let client = app.fileClient { NASFileBrowserView(client: client, owner: app.fileAccountID, folder: folder) }
                }
            }
            .environment(\.wideWorkspace, true)
            .environmentObject(navigation)
            .onChange(of: navigation.selection) { old, next in visited.insert(old); visited.insert(next) }
        }.navigationSplitViewStyle(.balanced)
            .background(MacWindowConfiguration())
    }
    private var path: Binding<NavigationPath> {
        let page = navigation.selection
        return Binding(get: { navigation.paths[page] ?? NavigationPath() }, set: { navigation.paths[page] = $0 })
    }
    private func sidebarGroup(_ title: String, pages: [WorkspacePage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.bottom, 4)
            ForEach(pages) { row($0) }
        }
    }
    private func row(_ page: WorkspacePage) -> some View {
        Button { navigation.selection = page; sidebarFocus = page } label: {
            HStack(spacing: 12) {
                Image(systemName: page.symbol).font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                Text(page.title).font(.subheadline.weight(navigation.selection == page ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }.foregroundStyle(navigation.selection == page ? NASStyle.accent : Color.primary.opacity(0.8))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(navigation.selection == page ? NASStyle.selection : hoveredPage == page ? NASStyle.inset : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .onHover { hoveredPage = $0 ? page : nil }
            .focusable()
            .focused($sidebarFocus, equals: page)
            .onKeyPress(.downArrow) { moveSidebar(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveSidebar(by: -1); return .handled }
            .accessibilityAddTraits(navigation.selection == page ? .isSelected : [])
            .accessibilityIdentifier("sidebar_" + page.rawValue)
    }
    private func moveSidebar(by offset: Int) {
        let pages: [WorkspacePage] = [.local, .photos, .files, .oneDrive, .calendar, .downloads, .monitor, .backup, .settings]
        guard let index = pages.firstIndex(of: navigation.selection), pages.indices.contains(index + offset) else { return }
        navigation.selection = pages[index + offset]
        sidebarFocus = pages[index + offset]
    }
    @ViewBuilder private func content(_ page: WorkspacePage) -> some View {
        switch page {
        case .local: LocalLibraryView(isActive: navigation.selection == page)
        case .photos: NASPhotosHomeView(isActive: navigation.selection == page)
        case .files: NASFilesHomeView(isActive: navigation.selection == page)
        case .downloads: NASDownloadsView(manager: app.downloads, owner: app.fileAccountID)
        case .monitor: NASMonitorHomeView(isActive: navigation.selection == page)
        case .backup: PhotoBackupView()
        case .settings: SettingsView().readableFormWidth()
        case .calendar: CalendarHomeView(isActive: navigation.selection == page)
        case .oneDrive: OneDriveHomeView(isActive: navigation.selection == page)
        }
    }
}

private struct MacWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { WindowView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
    private final class WindowView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 860, height: 580)
            #endif
        }
    }
}

extension View {
    @ViewBuilder func readableFormWidth() -> some View {
        if AppPlatform.isMac { frame(maxWidth: 760).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.canvas) }
        else { self }
    }
    @ViewBuilder func desktopSheet(width: CGFloat = 760, height: CGFloat = 600) -> some View {
        if AppPlatform.isMac { frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height) }
        else { self }
    }
}

private struct WideWorkspaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var wideWorkspace: Bool {
        get { self[WideWorkspaceKey.self] }
        set { self[WideWorkspaceKey.self] = newValue }
    }
}

private struct WorkspaceTitle: ViewModifier {
    @Environment(\.wideWorkspace) private var wide
    let title: String
    let detail: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if !wide || detail { content.navigationTitle(title) }
        else { content }
    }
}
extension View {
    func workspaceNavigationTitle(_ title: String, detail: Bool = false) -> some View { modifier(WorkspaceTitle(title: title, detail: detail)) }
    @ViewBuilder func activeFileSearch(_ query: Binding<String>, active: Bool) -> some View {
        if active { searchable(text: query, prompt: "搜索当前已载入的文件") }
        else { self }
    }
}
