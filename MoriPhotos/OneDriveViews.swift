import SwiftUI
import CryptoKit

/// Keeps navigation local to the cloud account; NAS paths are never used as drive IDs.
@MainActor final class OneDriveBrowserStore: ObservableObject {
    @Published private(set) var path: [OneDriveItem] = []
    @Published private(set) var items: [OneDriveItem] = []
    @Published private(set) var loading = false
    @Published private(set) var nextLink: URL?
    @Published private(set) var error: String?
    @Published private(set) var defaultName: String?
    private var history: [[OneDriveItem]] = [[]]
    private var index = 0
    private var generation = UUID()
    private var visitedLinks = Set<URL>()
    private let defaults: UserDefaults
    private var restoredDefault = false
    private var hasLoaded = false
    var canBack: Bool { index > 0 }
    var canForward: Bool { index + 1 < history.count }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func start(client: any OneDriveServing, accountID: String) async {
        guard !hasLoaded, !Task.isCancelled else { return }
        if !restoredDefault {
            restoredDefault = true
            if let data = defaults.data(forKey: bookmarkKey(accountID)),
               let saved = try? JSONDecoder().decode([OneDriveItem].self, from: data) {
                path = saved; history = [saved]; defaultName = saved.last?.name
            }
        }
        await refresh(client: client)
    }
    func open(_ folder: OneDriveItem, client: any OneDriveServing) async {
        guard folder.isFolder else { return }
        await navigate(path + [folder], client: client)
    }
    func navigate(_ next: [OneDriveItem], client: any OneDriveServing) async {
        history = Array(history.prefix(index + 1)); history.append(next); index += 1; path = next
        await refresh(client: client)
    }
    func back(client: any OneDriveServing) async { guard canBack else { return }; index -= 1; path = history[index]; await refresh(client: client) }
    func forward(client: any OneDriveServing) async { guard canForward else { return }; index += 1; path = history[index]; await refresh(client: client) }
    func refresh(client: any OneDriveServing) async {
        generation = UUID(); let ticket = generation
        loading = true; hasLoaded = false; error = nil; items = []; nextLink = nil; visitedLinks = []
        defer { if generation == ticket { loading = false } }
        do {
            try Task.checkCancellation()
            let page = try await client.children(of: path.last?.id, nextLink: nil)
            try Task.checkCancellation(); guard generation == ticket else { return }
            items = unique(page.items); nextLink = page.nextLink; hasLoaded = true
        } catch { if generation == ticket && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func more(client: any OneDriveServing) async {
        guard !loading, let link = nextLink else { return }
        guard !visitedLinks.contains(link) else { error = "云盘返回了重复的分页地址，请刷新目录。"; return }
        let ticket = generation; loading = true; error = nil
        defer { if generation == ticket { loading = false } }
        do {
            let page = try await client.children(of: path.last?.id, nextLink: link)
            try Task.checkCancellation(); guard generation == ticket else { return }
            visitedLinks.insert(link); items = unique(items + page.items); nextLink = page.nextLink
        } catch { if generation == ticket && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func saveDefault(accountID: String) {
        if path.isEmpty { defaults.removeObject(forKey: bookmarkKey(accountID)); defaultName = nil }
        else if let data = try? JSONEncoder().encode(path) { defaults.set(data, forKey: bookmarkKey(accountID)); defaultName = path.last?.name }
    }
    private func bookmarkKey(_ accountID: String) -> String {
        "onedrive.defaultFolder." + SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func unique(_ values: [OneDriveItem]) -> [OneDriveItem] {
        var seen = Set<String>(); return values.filter { seen.insert($0.id).inserted }
    }
}

struct StorageHomeView: View {
    var isActive = true
    @State private var oneDrive = false
    @State private var visitedOneDrive = false
    var body: some View {
        ZStack {
            NavigationStack { NASHomeView(isActive: isActive && !oneDrive).toolbar { ToolbarItem(placement: .topBarLeading) { sourceMenu } } }
                .opacity(oneDrive ? 0 : 1).allowsHitTesting(!oneDrive).accessibilityHidden(oneDrive)
            if visitedOneDrive {
                NavigationStack { OneDriveHomeView(isActive: isActive && oneDrive).toolbar { ToolbarItem(placement: .topBarLeading) { sourceMenu } } }
                    .opacity(oneDrive ? 1 : 0).allowsHitTesting(oneDrive).accessibilityHidden(!oneDrive)
            }
        }
    }
    private var sourceMenu: some View {
        Menu {
            Button { oneDrive = false } label: { Label("群晖", systemImage: "externaldrive") }
                .accessibilityIdentifier("storageChooseNAS")
            Button { visitedOneDrive = true; oneDrive = true } label: { Label("OneDrive", systemImage: "cloud") }
                .accessibilityIdentifier("storageChooseOneDrive")
        } label: {
            HStack(spacing: 4) { Image(systemName: oneDrive ? "cloud" : "externaldrive"); Image(systemName: "chevron.down").font(.caption2) }
        }.accessibilityLabel("切换存储位置").accessibilityIdentifier("storageSourceMenu")
    }
}

struct OneDriveHomeView: View {
    var isActive = true
    @EnvironmentObject private var session: OneDriveSession
    @State private var settings = false
    @State private var offlineDownloads = false
    var body: some View {
        Group {
            if let client = session.client, let account = session.account {
                OneDriveBrowserView(client: client, account: account, isActive: isActive).id(account.driveID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "cloud").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                                .frame(width: 56, height: 56).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                            Text("OneDrive").font(.title2.weight(.semibold))
                            Text("浏览照片和文件，按需下载到本机。").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if session.isConnecting { ProgressView("正在连接…") }
                        if let error = session.error {
                            ErrorBanner(message: error)
                            Button("重试已保存的连接") { Task { await session.restoreIfNeeded(retry: true) } }.disabled(session.isConnecting)
                        }
                        Button { settings = true } label: {
                            NASActionLabel(title: "连接微软账号", subtitle: "个人或工作 / 学校 OneDrive", symbol: "person.crop.circle")
                        }.buttonStyle(.plain).disabled(session.isConnecting).accessibilityIdentifier("connectOneDrive")
                        Button { offlineDownloads = true } label: {
                            Label("查看本机下载", systemImage: "arrow.down.circle").font(.subheadline)
                        }.buttonStyle(.borderless).accessibilityIdentifier("oneDriveOfflineDownloads")
                    }.padding(24).frame(maxWidth: 520, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 24)
                }.background(NASStyle.canvas)
            }
        }.workspaceNavigationTitle("OneDrive").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $settings) { NavigationStack { OneDriveConnectionView() }.desktopSheet(width: 620, height: 540) }
            .sheet(isPresented: $offlineDownloads) { NavigationStack { OneDriveDownloadsView(accountID: nil) }.desktopSheet() }
            .task(id: isActive) { if isActive { await session.restoreIfNeeded() } }
    }
}

struct OneDriveConnectionView: View {
    @EnvironmentObject private var session: OneDriveSession
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var disconnect = false
    var body: some View {
        Form {
            if let account = session.account {
                Section("已连接") {
                    Label(account.displayName, systemImage: "person.crop.circle.badge.checkmark")
                    Text("读取你的 OneDrive 文件。首次授权后会在本机保存登录状态。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Application (client) ID", text: $clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .accessibilityIdentifier("oneDriveClientID")
                    .disabled(session.client != nil || session.isConnecting)
                Text("填写微软应用注册中的客户端 ID，格式为带短横线的标识符。这里不填写邮箱或密码。").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("应用连接配置") }
            if let error = session.error { Section { ErrorBanner(message: error) } }
            if session.client == nil {
                Section {
                    Button {
                        session.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await session.connect(); if session.client != nil { dismiss() } }
                    } label: {
                        HStack { Spacer(); if session.isConnecting { ProgressView() }; Text(session.isConnecting ? "等待微软授权…" : "登录微软账号"); Spacer() }
                    }.disabled(UUID(uuidString: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || session.isConnecting)
                        .accessibilityIdentifier("oneDriveSignIn")
                } footer: { Text("将打开微软登录页面，只申请文件读取权限。支持全球版个人与工作/学校账号，具体取决于应用注册的账号类型。暂不读取其他网盘或共享库的快捷方式。") }
            } else {
                Section { Button("退出 OneDrive", role: .destructive) { disconnect = true }.accessibilityIdentifier("oneDriveSignOut") }
            }
            Section {
                DisclosureGroup("首次配置帮助") {
                    Text("在 Microsoft Entra → 应用注册 → 你的应用 → 身份验证中添加移动和桌面应用平台，并登记以下回调地址：").font(.footnote)
                    Text(OneDriveSession.redirectURI).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("个人 OneDrive 需在受支持账户类型中包含个人 Microsoft 账户。不需要创建客户端密码。").font(.footnote).foregroundStyle(.secondary)
                    Link("打开微软应用注册", destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                }
            }
        }.scrollContentBackground(.hidden).background(NASStyle.canvas)
            .navigationTitle("OneDrive 连接").navigationBarTitleDisplayMode(.inline)
            .onAppear { clientID = session.clientID }
            .interactiveDismissDisabled(session.isConnecting)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(session.isConnecting) } }
            .confirmationDialog("退出会移除本机登录状态并取消正在进行的传输。已下载文件保留在本机。", isPresented: $disconnect, titleVisibility: .visible) {
                Button("退出账号", role: .destructive) {
                    if let id = session.account?.driveID { OneDriveMediaStore.shared.cancel(accountID: id) }
                    Task { await session.disconnect(); if session.client == nil { dismiss() } }
                }
            }
    }
}

private enum OneDriveSort: String, CaseIterable { case name = "名称", date = "修改时间", size = "大小" }

struct OneDriveBrowserView: View {
    let client: any OneDriveServing
    let account: OneDriveAccount
    var isActive = true
    @Environment(\.wideWorkspace) private var wide
    @StateObject private var store = OneDriveBrowserStore()
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var grid = false
    @State private var sort = OneDriveSort.name
    @State private var selected: OneDriveItem?
    @State private var detail: OneDriveItem?
    @State private var preview: OneDriveItem?
    @State private var video: OneDriveItem?
    @State private var settings = false
    @State private var downloads = false
    @State private var savedDefault = false
    @State private var pending: OneDrivePresentation?
    @State private var hoveredItem: String?
    private var items: [OneDriveItem] {
        store.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            switch sort {
            case .date: if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            case .size: if $0.size != $1.size { return ($0.size ?? 0) > ($1.size ?? 0) }
            case .name: break
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = store.error {
                HStack { ErrorBanner(message: error); Button("重试") { Task { await store.refresh(client: client) } } }.padding(12)
            }
            if savedDefault { Text(store.defaultName.map { "已将 \($0) 设为默认入口" } ?? "默认入口已设为我的文件").font(.caption).foregroundStyle(Theme.accent).padding(6) }
            HStack(spacing: 0) {
                fileContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide, let selected {
                    Divider()
                    ScrollView { itemDetails(selected).padding(20) }.frame(width: 272)
                        .background(NASStyle.surface)
                }
            }
            Divider()
            HStack {
                Text(query.isEmpty ? "已载入 \(store.items.count) 项" : "\(items.count) 项匹配已载入内容")
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                else if store.nextLink != nil { Button("加载更多") { Task { await store.more(client: client) } }.accessibilityIdentifier("oneDriveLoadMore") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, wide ? 22 : 16).frame(minHeight: 36)
                .background(NASStyle.surface.opacity(0.65))
        }.background(NASStyle.canvas)
            .onChange(of: isActive) { _, active in if !active { searchFocused = false } }
            .task(id: isActive) { if isActive { await store.start(client: client, accountID: account.driveID) } }
            .sheet(item: $detail, onDismiss: presentPending) { item in NavigationStack { ScrollView { itemDetails(item).padding(20) }.navigationTitle("文件信息").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { detail = nil } } } }.desktopSheet() }
            .sheet(item: $preview) { item in OneDrivePreviewView(item: item, client: client, accountID: account.driveID).desktopSheet() }
            .fullScreenCover(item: $video) { item in OneDrivePlaybackView(item: item, client: client, accountID: account.driveID) }
            .sheet(isPresented: $settings) { NavigationStack { OneDriveConnectionView() }.desktopSheet(width: 620, height: 540) }
            .sheet(isPresented: $downloads) { NavigationStack { OneDriveDownloadsView(accountID: account.driveID) }.desktopSheet() }
    }
    private var controls: some View {
        VStack(spacing: wide ? 14 : 10) {
            HStack(spacing: 14) {
                if wide {
                    Button { selected = nil; Task { await store.back(client: client) } } label: { Image(systemName: "chevron.left") }.disabled(!store.canBack).accessibilityLabel("后退")
                    Button { selected = nil; Task { await store.forward(client: client) } } label: { Image(systemName: "chevron.right") }.disabled(!store.canForward).accessibilityLabel("前进")
                    Divider().frame(height: 16)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { go([]) } label: { Label("我的文件", systemImage: "cloud") }.accessibilityIdentifier("oneDriveRoot")
                        ForEach(Array(store.path.enumerated()), id: \.element.id) { index, folder in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Button(folder.name) { go(Array(store.path.prefix(index + 1))) }.lineLimit(1)
                                .foregroundStyle(index == store.path.count - 1 ? Color.primary : Color.secondary)
                        }
                    }.font(.subheadline).fixedSize(horizontal: true, vertical: false)
                }
                if !wide {
                    Button { withAnimation(.easeOut(duration: 0.18)) { showingSearch.toggle(); if !showingSearch { query = "" } }; searchFocused = showingSearch } label: {
                        Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                    }.accessibilityLabel(showingSearch ? "关闭搜索" : "搜索文件")
                }
                Button { downloads = true } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("OneDrive 下载").accessibilityIdentifier("oneDriveDownloads")
                Menu {
                    Picker("排序已载入内容", selection: $sort) { ForEach(OneDriveSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Button(grid ? "列表显示" : "图标显示", systemImage: grid ? "list.bullet" : "square.grid.2x2") { grid.toggle() }
                    Button("将此目录设为默认入口", systemImage: "star") { store.saveDefault(accountID: account.driveID); savedDefault = true }
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh(client: client) } }
                    Button("账号设置", systemImage: "person.crop.circle") { settings = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("OneDrive 更多操作").accessibilityIdentifier("oneDriveMore")
            }.frame(minHeight: 30)
            if wide {
                HStack(spacing: 16) {
                    Text(store.path.last?.name ?? "我的文件").font(.headline).lineLimit(1)
                    Spacer(minLength: 12)
                    searchField.frame(width: 240)
                    HStack(spacing: 2) {
                        layoutButton(isGrid: true, symbol: "square.grid.2x2", label: "图标视图")
                        layoutButton(isGrid: false, symbol: "list.bullet", label: "列表视图")
                    }.padding(3).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if showingSearch { searchField }
        }.buttonStyle(.borderless).padding(.horizontal, wide ? 22 : 16).padding(.vertical, 12)
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索当前已载入的文件", text: $query).textFieldStyle(.plain)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($searchFocused)
                .accessibilityIdentifier("oneDriveSearch")
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清除搜索") }
        }.font(.subheadline).padding(.horizontal, 10).frame(height: wide ? 32 : 40)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
    }
    private func layoutButton(isGrid: Bool, symbol: String, label: String) -> some View {
        Button { grid = isGrid } label: {
            Image(systemName: symbol).frame(width: 30, height: 25)
                .foregroundStyle(grid == isGrid ? Theme.accent : Color.secondary)
                .background(grid == isGrid ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
    @ViewBuilder private var fileContent: some View {
        if store.loading && store.items.isEmpty { ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if items.isEmpty && store.error == nil {
            ContentUnavailableView(query.isEmpty ? "文件夹为空" : "没有匹配的文件", systemImage: "folder", description: Text(query.isEmpty ? "这里还没有文件。" : "搜索范围为当前已载入的文件。"))
        } else {
            ScrollView {
                if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 140 : 100, maximum: 190), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            itemButton(item) {
                                VStack(spacing: 10) {
                                    Image(systemName: item.icon).font(.system(size: 34, weight: .light)).symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(item.isFolder ? Theme.accent : Color.secondary).frame(width: 60, height: 60)
                                        .background(item.isFolder ? Theme.accent.opacity(0.075) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                                    Text(item.name).font(.caption.weight(.medium)).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center).frame(height: 34, alignment: .top)
                                    Text(item.isFolder ? "文件夹" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "文件")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 16)
                                    .background(selected?.id == item.id ? Theme.accent.opacity(0.1) : NASStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(selected?.id == item.id ? Theme.accent.opacity(0.45) : hoveredItem == item.id ? Theme.accent.opacity(0.22) : NASStyle.outline, lineWidth: 1) }
                            }
                        }
                    }.padding(wide ? 22 : 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            itemButton(item) { OneDriveItemRow(item: item).padding(.horizontal, wide ? 22 : 16).padding(.vertical, 11)
                                    .background(selected?.id == item.id ? Theme.accent.opacity(0.1) : hoveredItem == item.id ? Color.primary.opacity(0.035) : .clear) }
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }.refreshable { await store.refresh(client: client) }
        }
    }
    private func itemButton<Content: View>(_ item: OneDriveItem, @ViewBuilder content: () -> Content) -> some View {
        content().contentShape(Rectangle()).onHover { hoveredItem = $0 ? item.id : nil }.onTapGesture(count: 2) { open(item) }
            .onTapGesture { searchFocused = false; if wide { selected = item } else { open(item) } }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { open(item) }.accessibilityIdentifier("oneDriveItem_" + item.id)
            .contextMenu {
                Button(item.isFolder ? "打开文件夹" : "打开", systemImage: item.isFolder ? "folder" : "doc") { open(item) }
                if !item.isFolder { Button("下载", systemImage: "arrow.down.circle") { download(item) } }
                Button("文件信息", systemImage: "info.circle") { detail = item }
            }
    }
    @ViewBuilder private func itemDetails(_ item: OneDriveItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: item.icon).font(.system(size: 42, weight: .light)).symbolRenderingMode(.hierarchical).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 110).background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(item.isFolder ? "OneDrive 文件夹" : "OneDrive 文件").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let size = item.size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            if let modified = item.modified { LabeledContent("修改时间", value: modified.formatted(date: .abbreviated, time: .shortened)) }
            Divider()
            if item.isFolder { Button("打开文件夹") { detail = nil; go(store.path + [item]) } }
            else {
                if item.isVideo { Button("直接播放视频", systemImage: "play.circle") { present(.video(item)) }.disabled(!item.canPlayNatively).accessibilityIdentifier("oneDrivePlay") }
                Button("预览文件", systemImage: "doc.text.magnifyingglass") { present(.preview(item)) }.accessibilityIdentifier("oneDrivePreview")
                Button(AppPlatform.downloadTitle, systemImage: "arrow.down.circle") { download(item) }.accessibilityIdentifier("oneDriveDownload")
                Text("预览支持 30 MB 以内的常见图片和文档；其他文件可下载后打开。").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.subheadline).buttonStyle(.bordered).controlSize(.regular).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func go(_ path: [OneDriveItem]) { selected = nil; query = ""; savedDefault = false; Task { await store.navigate(path, client: client) } }
    private func open(_ item: OneDriveItem) {
        if item.isFolder { go(store.path + [item]) }
        else { detail = item }
    }
    private func download(_ item: OneDriveItem) { _ = OneDriveMediaStore.shared.enqueue(item: item, client: client, accountID: account.driveID); present(.downloads) }
    private func present(_ action: OneDrivePresentation) {
        pending = action
        if detail != nil { detail = nil } else { presentPending() }
    }
    private func presentPending() {
        guard let action = pending else { return }; pending = nil
        switch action { case .preview(let item): preview = item; case .video(let item): video = item; case .downloads: downloads = true }
    }
}
private enum OneDrivePresentation { case preview(OneDriveItem), video(OneDriveItem), downloads }

struct OneDriveItemRow: View {
    let item: OneDriveItem
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.icon).font(.system(size: 22)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.isFolder ? Theme.accent : Color.secondary).frame(width: 42, height: 42)
                .background(item.isFolder ? Theme.accent.opacity(0.085) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    if !item.isFolder, let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let date = item.modified { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OneDriveDownloadsView: View {
    let accountID: String?
    @ObservedObject private var media = OneDriveMediaStore.shared
    @EnvironmentObject private var session: OneDriveSession
    @Environment(\.dismiss) private var dismiss
    @State private var export: OneDriveExportSelection?
    @State private var remove: OneDriveDownloadRecord?
    @State private var localPreview: OneDriveExportSelection?
    @State private var retryError: String?
    private var records: [OneDriveDownloadRecord] { accountID.map { media.records(for: $0) } ?? media.records }
    var body: some View {
        List {
            Section { Text(accountID == nil ? "这里显示本机保存的 OneDrive 下载，退出账号后仍可预览和导出。" : "下载时保持 App 在前台。已完成的文件保存在本机，可以离线导出。").font(.footnote).foregroundStyle(.secondary) }
            if let error = media.error { Section { ErrorBanner(message: error) } }
            if let retryError { Section { ErrorBanner(message: retryError) } }
            if records.isEmpty { ContentUnavailableView("没有下载记录", systemImage: "arrow.down.circle") }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.name).font(.headline).lineLimit(2)
                    HStack {
                        Text(record.state.title).accessibilityIdentifier("oneDriveDownloadState")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file)).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                    if let message = record.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if record.state.active { Button("取消下载") { media.cancel(id: record.id) } }
                    if let url = media.localURL(for: record) {
                        Button("打开已下载文件", systemImage: "doc.text.magnifyingglass") { localPreview = OneDriveExportSelection(url: url) }.accessibilityIdentifier("oneDriveOpenDownload")
                        HStack {
                            Button("保存到所选位置", systemImage: "square.and.arrow.down") { export = OneDriveExportSelection(url: url) }.accessibilityIdentifier("oneDriveExport")
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享下载文件")
                            Spacer()
                            Button("移除本机文件", role: .destructive) { remove = record }
                        }.buttonStyle(.borderless).font(.subheadline)
                    } else if !record.state.active {
                        if let accountID, session.account?.driveID == accountID, let client = session.client {
                            Button("重新下载") { Task {
                                do { let item = try await client.item(id: record.itemID); _ = media.enqueue(item: item, client: client, accountID: accountID); retryError = nil }
                                catch { retryError = error.localizedDescription }
                            } }
                        }
                        Button("移除记录", role: .destructive) { remove = record }
                    }
                }.padding(.vertical, 6)
            }
        }.scrollContentBackground(.hidden).background(NASStyle.canvas)
            .navigationTitle("OneDrive 下载").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.accessibilityIdentifier("oneDriveDownloadsDone") } }
            .sheet(item: $export) { selection in FileExportSheet(url: selection.url) { _ in export = nil } }
            .sheet(item: $localPreview) { selection in NavigationStack { OneDriveNativeQuickLook(url: selection.url).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { localPreview = nil } } } }.desktopSheet() }
            .confirmationDialog("移除这个本机下载？OneDrive 中的原文件会保留。", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("移除本机下载", role: .destructive) { if let remove { media.remove(record: remove) }; remove = nil }
            }
    }
}
private struct OneDriveExportSelection: Identifiable { let id = UUID(); let url: URL }
