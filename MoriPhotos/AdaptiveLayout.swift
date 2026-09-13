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
    case local, photos, files, downloads, monitor, backup, settings
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
        }
    }
}

@MainActor final class WorkspaceNavigation: ObservableObject {
    @Published var selection: WorkspacePage = .photos
    @Published var paths: [WorkspacePage: NavigationPath] = [:]
}

struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var navigation: WorkspaceNavigation
    var body: some View {
        if AppPlatform.isMac || sizeClass == .regular {
            DesktopWorkspaceView(navigation: navigation)
        } else {
            TabView {
                NavigationStack { LocalLibraryView() }.tabItem { Label("照片", systemImage: "square.grid.2x2") }
                NavigationStack { NASHomeView() }.tabItem { Label("群晖", systemImage: "externaldrive") }
                NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

struct DesktopWorkspaceView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var navigation: WorkspaceNavigation
    @State private var visited: Set<WorkspacePage> = [.photos]
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List {
                Section("图库") { row(.local); row(.photos) }
                Section("群晖 NAS") { row(.files); row(.downloads); row(.monitor) }
                Section("管理") { row(.backup); row(.settings) }
            }.listStyle(.sidebar).environment(\.defaultMinListRowHeight, 28).navigationTitle("森空间")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                .accessibilityIdentifier("workspaceSidebar")
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
    private func row(_ page: WorkspacePage) -> some View {
        Button { navigation.selection = page } label: {
            Label(page.title, systemImage: page.symbol)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                .foregroundStyle(navigation.selection == page ? Theme.accent : Color.primary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .listRowBackground(navigation.selection == page ? Theme.accent.opacity(0.14) : Color.clear)
            .accessibilityAddTraits(navigation.selection == page ? .isSelected : [])
            .accessibilityIdentifier("sidebar_" + page.rawValue)
    }
    @ViewBuilder private func content(_ page: WorkspacePage) -> some View {
        switch page {
        case .local: LocalLibraryView(isActive: navigation.selection == page)
        case .photos: NASPhotosHomeView(isActive: navigation.selection == page)
        case .files: NASFilesHomeView(isActive: navigation.selection == page)
        case .downloads: NASDownloadsView(manager: app.downloads, owner: app.fileAccountID)
        case .monitor: NASMonitorHomeView(isActive: navigation.selection == page)
        case .backup: PhotoBackupView().readableFormWidth()
        case .settings: SettingsView().readableFormWidth()
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
        if AppPlatform.isMac { frame(maxWidth: 780).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas) }
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
