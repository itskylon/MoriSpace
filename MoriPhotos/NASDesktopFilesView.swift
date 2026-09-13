import SwiftUI

struct NASDesktopFilesView: View {
    let client: SynologyClient
    let owner: String
    var isActive: Bool
    @StateObject private var navigation = DesktopFileNavigation()
    var body: some View {
        DesktopFileContents(client: client, owner: owner, isActive: isActive,
                            navigation: navigation, directory: navigation.current, store: navigation.current.store)
    }
}

private struct DesktopFileContents: View {
    let client: SynologyClient
    let owner: String
    var isActive: Bool
    @ObservedObject var navigation: DesktopFileNavigation
    @ObservedObject var directory: DesktopFileDirectory
    @ObservedObject var store: NASFileBrowserStore
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var workspace: WorkspaceNavigation
    @AppStorage("desktopFilesLayout") private var layout = "icons"
    @State private var inspector = false
    @State private var connection = false
    @State private var preview: NASFile?
    @State private var video: VideoSelection?
    @State private var downloadNotice: String?
    @FocusState private var searchFocused: Bool
    private var matchingFiles: [NASFile] { store.items.filter { directory.query.isEmpty || $0.name.localizedCaseInsensitiveContains(directory.query) } }
    private var selected: NASFile? { store.items.first { $0.id == directory.selection } }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            controls
            if let error = store.error {
                HStack {
                    ErrorBanner(message: error)
                    Button("重试") { Task { await refresh() } }.padding(.trailing, 16)
                }
            }
            HStack(spacing: 0) {
                Group { if layout == "icons" { iconGrid } else { fileTable } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { emptyState }
                if inspector {
                    Divider()
                    information.frame(width: 240)
                }
            }
            Divider()
            statusBar
        }
        .background(NASStyle.canvas)
        .task(id: directory.key + directory.sortKey) {
            if directory.loadedSort != directory.sortKey { await refresh() }
        }
        .sheet(item: $preview) { NASQuickPreview(file: $0, client: client, owner: owner) }
        .fullScreenCover(item: $video) { VideoPlaybackView(selection: $0, client: client) }
        .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .files) }.desktopSheet() }
        .toolbar {
            if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("下载任务", systemImage: "arrow.down.circle") { workspace.selection = .downloads }
                        Button("文件连接设置", systemImage: "externaldrive") { connection = true }
                    } label: { Image(systemName: "ellipsis") }.help("文件选项")
                }
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { navigation.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(navigation.back.isEmpty).keyboardShortcut("[", modifiers: .command)
                .help("后退 ⌘[").accessibilityLabel("后退").accessibilityIdentifier("filesBack")
            Button { navigation.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(navigation.forward.isEmpty).keyboardShortcut("]", modifiers: .command)
                .help("前进 ⌘]").accessibilityLabel("前进").accessibilityIdentifier("filesForward")
            Button { navigation.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!navigation.canGoUp).keyboardShortcut(.upArrow, modifiers: .command)
                .help("上一级 ⌘↑").accessibilityLabel("上一级").accessibilityIdentifier("filesUp")
            Divider().frame(height: 18).padding(.horizontal, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Button { navigation.open(nil) } label: { Label("群晖", systemImage: "externaldrive") }
                        .accessibilityIdentifier("filesRoot")
                    ForEach(navigation.breadcrumbs) { folder in
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        Button(folder.name) { navigation.open(folder) }
                            .foregroundStyle(folder.path == directory.key ? Color.primary : Color.secondary)
                            .accessibilityIdentifier("breadcrumb_" + folder.name)
                    }
                }.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }.scrollIndicators(.hidden)
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.loading).keyboardShortcut("r").help("刷新目录 ⌘R").accessibilityLabel("刷新目录")
        }.buttonStyle(.borderless).font(.system(size: 13, weight: .medium)).padding(.horizontal, 18).frame(height: 46)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text(directory.folder?.name ?? "共享文件夹").font(.title3.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索已载入的文件", text: $directory.query).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityIdentifier("desktopFileSearch")
                if !directory.query.isEmpty {
                    Button { directory.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(width: 200, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Picker("排序", selection: $directory.sort) {
                    ForEach(FileSort.allCases.filter { directory.folder != nil || $0 != .size }) { Text($0.title).tag($0) }
                }
                Toggle("升序排列", isOn: $directory.ascending)
            } label: { Image(systemName: "arrow.up.arrow.down") }.help("排序").accessibilityLabel("排序")
            HStack(spacing: 2) {
                viewButton("icons", symbol: "square.grid.2x2", title: "图标视图")
                viewButton("list", symbol: "list.bullet", title: "列表视图")
            }.padding(3).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Button { inspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .foregroundStyle(inspector ? NASStyle.accent : Color.secondary).help("显示或隐藏信息")
                .accessibilityLabel("显示或隐藏信息").accessibilityIdentifier("filesInspector")
        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func viewButton(_ value: String, symbol: String, title: String) -> some View {
        Button { layout = value } label: {
            Image(systemName: symbol).frame(width: 28, height: 25)
                .foregroundStyle(layout == value ? NASStyle.accent : Color.secondary)
                .background(layout == value ? NASStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityIdentifier("filesView_" + value)
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                ForEach(matchingFiles) { file in
                    VStack(spacing: 8) {
                        Image(systemName: file.isdir ? "folder.fill" : file.icon)
                            .font(.system(size: 42, weight: .light)).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(file.isdir ? NASStyle.accent : Color.secondary).frame(height: 52)
                        Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            .multilineTextAlignment(.center).truncationMode(.middle).frame(height: 32, alignment: .top)
                        Text(file.isdir ? "文件夹" : size(file)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 8)
                        .background(directory.selection == file.id ? NASStyle.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(directory.selection == file.id ? NASStyle.accent.opacity(0.4) : Color.clear) }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { directory.selection = file.id; open(file) }
                        .onTapGesture { directory.selection = file.id; searchFocused = false }
                        .contextMenu { fileActions(file) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(directory.selection == file.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { directory.selection = file.id; open(file) }
                        .accessibilityIdentifier((file.isdir ? "nasFolder_" : "nasFile_") + file.name)
                }
            }.padding(.horizontal, 18).padding(.bottom, 18)
        }.accessibilityIdentifier("desktopFileGrid")
    }
    private var fileTable: some View {
        Table(matchingFiles, selection: $directory.selection) {
            TableColumn("名称") { file in
                Label(file.name, systemImage: file.isdir ? "folder.fill" : file.icon)
                    .foregroundStyle(file.isdir ? NASStyle.accent : Color.primary)
            }.width(min: 180, ideal: 320)
            TableColumn("种类") { Text($0.kindLabel).foregroundStyle(.secondary) }.width(min: 70, ideal: 90, max: 120)
            TableColumn("大小") { Text(size($0)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 85, max: 110)
            TableColumn("修改时间") { Text($0.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary) }
                .width(min: 130, ideal: 160)
        }.contextMenu(forSelectionType: String.self) { ids in
            if let file = store.items.first(where: { ids.contains($0.id) }) { fileActions(file) }
        } primaryAction: { ids in
            if let file = store.items.first(where: { ids.contains($0.id) }) { open(file) }
        }.accessibilityIdentifier("desktopFileTable")
    }
    @ViewBuilder private var emptyState: some View {
        if store.loading && store.items.isEmpty { ProgressView("正在读取文件…") }
        else if matchingFiles.isEmpty && store.error == nil {
            ContentUnavailableView(directory.query.isEmpty ? (directory.folder == nil ? "没有可访问的共享文件夹" : "空文件夹") : "没有匹配的文件",
                                   systemImage: directory.query.isEmpty ? "folder" : "magnifyingglass",
                                   description: Text(directory.query.isEmpty ? "" : "仅搜索当前已载入的内容。"))
        }
    }
    private var information: some View {
        ScrollView {
            if let file = selected {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: file.isdir ? "folder.fill" : file.icon).font(.system(size: 54, weight: .light))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(NASStyle.accent).frame(maxWidth: .infinity).padding(.top, 16)
                    Text(file.name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(file.kindLabel).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    infoRow("大小", value: size(file))
                    infoRow("修改时间", value: file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    infoRow("位置", value: file.path)
                    Divider()
                    Button(openTitle(file), systemImage: file.isdir ? "folder" : file.canPlayNatively ? "play.fill" : "eye") { open(file) }
                        .disabled(!file.isdir && !file.canPlayNatively && !file.canQuickLook)
                    if !file.isdir { Button(AppPlatform.downloadTitle, systemImage: "arrow.down.circle") { download(file) } }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("文件信息", systemImage: "info.circle", description: Text("选择文件查看大小、修改时间和位置。"))
            }
        }.background(Color.primary.opacity(0.025)).accessibilityIdentifier("fileInspectorPanel")
    }
    private func infoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(directory.query.isEmpty ? "\(store.items.count) / \(store.total) 项" : "匹配 \(matchingFiles.count) 项 · 已载入 \(store.items.count) / \(store.total) 项")
                .monospacedDigit().accessibilityIdentifier("fileCount")
            if selected != nil { Text("已选 1 项") }
            if let downloadNotice {
                Button { workspace.selection = .downloads } label: { Label(downloadNotice, systemImage: "checkmark.circle") }
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if store.loading { ProgressView().controlSize(.small) }
            else if store.hasMore {
                Button("载入更多") { Task { await store.loadMore(client: client, path: directory.folder?.path, sort: directory.sort, ascending: directory.ascending) } }
                    .accessibilityIdentifier("moreFiles")
            }
            Button(selected.map(openTitle) ?? "打开") { if let selected { open(selected) } }
                .disabled(selected == nil || searchFocused).keyboardShortcut("o", modifiers: .command)
                .help("打开所选项目 ⌘O").accessibilityIdentifier("filesOpen")
        }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 36)
    }
    @ViewBuilder private func fileActions(_ file: NASFile) -> some View {
        Button(openTitle(file)) { directory.selection = file.id; open(file) }
        if !file.isdir { Button(AppPlatform.downloadTitle) { download(file) } }
        Divider()
        Button("显示信息") { directory.selection = file.id; inspector = true }
        Button("复制路径") { UIPasteboard.general.string = file.path }
    }
    private func openTitle(_ file: NASFile) -> String {
        file.isdir ? "打开文件夹" : file.canPlayNatively ? "播放视频" : file.canQuickLook ? "快速预览" : "显示信息"
    }
    private func open(_ file: NASFile) {
        searchFocused = false
        if file.isdir { navigation.open(file) }
        else if file.canPlayNatively { video = VideoSelection(file: file, owner: owner) }
        else if file.canQuickLook { preview = file }
        else { directory.selection = file.id; inspector = true }
    }
    private func download(_ file: NASFile) {
        app.downloads.enqueue(file, owner: owner, client: client); downloadNotice = "已加入下载"
    }
    private func size(_ file: NASFile) -> String { file.isdir ? "—" : file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
    private func refresh() async {
        let target = directory, sorting = target.sortKey
        await target.store.reset(client: client, path: target.folder?.path, sort: target.sort, ascending: target.ascending)
        if !Task.isCancelled { target.loadedSort = sorting }
    }
}
