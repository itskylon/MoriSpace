import SwiftUI
import UniformTypeIdentifiers

struct NASFilesHomeView: View {
    var isActive = true
    @EnvironmentObject private var app: AppState
    @State private var connect = false
    private var useDesktopBrowser: Bool {
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if ProcessInfo.processInfo.arguments.contains("--desktop-files-fixture") { return true }
        #endif
        return AppPlatform.isMac
    }
    var body: some View {
        Group {
            if let client = app.fileClient {
                Group {
                    if useDesktopBrowser { NASDesktopFilesView(client: client, owner: app.fileAccountID, isActive: isActive) }
                    else { NASFileBrowserView(client: client, owner: app.fileAccountID, isActive: isActive) }
                }.id(app.fileConnectionID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        StorageConnectionHeading(title: "群晖文件", detail: "浏览共享文件夹，下载需要的文件", symbol: "folder", color: NASStyle.accent)
                        NASConnectionStatus(service: .files)
                        Button { connect = true } label: {
                            NASActionLabel(title: app.hasSavedConnection ? "文件连接设置" : "连接群晖文件", subtitle: "File Station", symbol: "folder")
                        }.buttonStyle(.plain).accessibilityIdentifier("connectFiles")
                        NavigationLink { NASDownloadsView(manager: app.downloads, owner: app.fileAccountID).toolbar(.visible, for: .navigationBar) } label: {
                            NASActionLabel(title: "下载", subtitle: "任务与离线文件", symbol: "arrow.down.circle")
                        }.buttonStyle(.plain).accessibilityIdentifier("openDownloads")
                    }.padding(20).frame(maxWidth: 520, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.background(NASStyle.canvas)
            }
        }.sheet(isPresented: $connect) { NavigationStack { ConnectionView(service: .files) }.desktopSheet() }
            .task(id: isActive) { if isActive { await app.restoreConnection(service: .files) } }
    }
}

struct NASFileBrowserView: View {
    @Environment(\.wideWorkspace) private var wideWorkspace
    @EnvironmentObject private var app: AppState
    let client: SynologyClient
    let owner: String
    var isActive = true
    var folder: NASFile? = nil
    @StateObject private var store = NASFileBrowserStore()
    @State private var sort = FileSort.name
    @State private var ascending = true
    @State private var selected: NASFile?
    @State private var connection = false
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    private var filteredItems: [NASFile] { store.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    private var sorting: String { sort.rawValue + String(ascending) }
    var body: some View {
        mobileBrowser
        .workspaceNavigationTitle(folder?.name ?? "群晖文件", detail: folder != nil).navigationBarTitleDisplayMode(.inline)
        .task(id: sorting) { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected) { file in NavigationStack { NASFileDetailView(file: file, client: client, owner: owner) }.desktopSheet() }
        .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .files) }.desktopSheet() }
        .onChange(of: isActive) { _, active in if !active { searchFocused = false } }
        .onDisappear { searchFocused = false }
    }
    private var optionsMenu: some View {
        Menu {
            NavigationLink { NASDownloadsView(manager: app.downloads, owner: owner).toolbar(.visible, for: .navigationBar) } label: {
                Label("下载任务与已下载", systemImage: "arrow.down.circle")
            }.accessibilityIdentifier("openDownloads")
            Picker("排序", selection: $sort) { ForEach(FileSort.allCases.filter { folder != nil || $0 != .size }) { Text($0.title).tag($0) } }
            Toggle("升序排列", isOn: $ascending)
            Button("文件连接设置") { connection = true }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(Color.primary).frame(width: 44, height: 44)
        }.accessibilityLabel("文件选项").accessibilityIdentifier("fileOptions")
    }
    private var searchToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showingSearch.toggle(); if !showingSearch { query = "" } }
            searchFocused = showingSearch
        } label: {
            Image(systemName: showingSearch ? "xmark" : "magnifyingglass").frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(NASStyle.accent)
            .accessibilityLabel(showingSearch ? "关闭搜索" : "搜索文件")
            .accessibilityIdentifier("toggleNASFileSearch")
    }
    private var fileControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder == nil ? "共享文件夹" : "文件").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(query.isEmpty ? "\(store.items.count) / \(store.total) 项" : "\(filteredItems.count) 项匹配")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("fileCount")
                }
                Spacer()
                searchToggle
                optionsMenu
            }
            if let folder { Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            if showingSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索已载入的文件", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                        .accessibilityIdentifier("nasFileSearch")
                }.font(.subheadline).padding(.horizontal, 10).frame(minHeight: 44)
                    .background(NASStyle.inset, in: RoundedRectangle(cornerRadius: 12)).padding(.trailing, 8)
            }
        }.buttonStyle(.plain).padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
    }
    private var mobileBrowser: some View {
        VStack(spacing: 0) {
            fileControls
            Rectangle().fill(NASStyle.outline).frame(height: 0.5)
            List {
                if let error = store.error {
                    Section {
                        ErrorBanner(message: error)
                        Button("重试读取") { Task { await refresh() } }
                    }.listRowBackground(NASStyle.canvas)
                }
                Section {
                    ForEach(filteredItems) { file in
                        if file.isdir {
                            if wideWorkspace {
                                NavigationLink(value: file) { NASFileRow(file: file) }.accessibilityIdentifier("nasFolder_" + file.name)
                            } else {
                                NavigationLink { NASFileBrowserView(client: client, owner: owner, folder: file).toolbar(.visible, for: .navigationBar) } label: { NASFileRow(file: file) }
                                    .accessibilityIdentifier("nasFolder_" + file.name)
                            }
                        } else {
                            Button { searchFocused = false; selected = file } label: { NASFileRow(file: file) }
                                .buttonStyle(.plain).accessibilityIdentifier("nasFile_" + file.name)
                        }
                    }
                    if store.loading { HStack { Spacer(); ProgressView("正在读取文件…"); Spacer() }.padding() }
                    else if store.hasMore && store.error == nil {
                        Button("载入更多") { Task { await store.loadMore(client: client, path: folder?.path, sort: sort, ascending: ascending) } }.accessibilityIdentifier("moreFiles")
                    } else if filteredItems.isEmpty && store.error == nil {
                        ContentUnavailableView(query.isEmpty ? (folder == nil ? "没有可访问的共享文件夹" : "这是一个空文件夹") : "没有匹配的文件", systemImage: query.isEmpty ? "folder" : "magnifyingglass", description: Text(query.isEmpty ? (folder == nil ? "请检查账号的共享文件夹权限。" : "可以返回上级继续浏览。") : "搜索范围为当前已载入的文件。"))
                    }
                }.listRowBackground(NASStyle.canvas)
            }.listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.top, 0, for: .scrollContent)
        }.background(NASStyle.canvas)
    }
    private func refresh() async { await store.reset(client: client, path: folder?.path, sort: sort, ascending: ascending) }
}

struct NASFileRow: View {
    let file: NASFile
    var body: some View {
        HStack(spacing: 12) {
            StorageFileBadge(name: file.name, symbol: file.isdir ? "folder.fill" : file.icon, folder: file.isdir)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    if !file.isdir, let size = file.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let date = file.modified { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.vertical, 5)
    }
}

struct NASFileDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let file: NASFile
    let client: SynologyClient
    let owner: String
    @State private var added = false
    @State private var video: VideoSelection?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StorageFileBadge(name: file.name, symbol: file.icon, folder: false, expanded: true).frame(width: 82)
                VStack(alignment: .leading, spacing: 10) {
                    Text(file.name).font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let size = file.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let modified = file.modified {
                        Text("修改于 " + modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("所在位置").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(file.path).font(.footnote.monospaced()).textSelection(.enabled)
                }
                Rectangle().fill(NASStyle.outline).frame(height: 1)
                if file.isVideo {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { video = VideoSelection(file: file, owner: owner) } label: {
                            StoragePrimaryAction(title: "直接播放视频", symbol: "play.fill")
                        }.buttonStyle(.plain).accessibilityIdentifier("playVideo")
                        Text("支持本机可解码的 MP4、MOV 等视频。在线播放需要 NAS 支持分段读取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        app.downloads.enqueue(file, owner: owner, client: client); added = true
                    } label: {
                        StoragePrimaryAction(title: added ? "已加入下载队列" : AppPlatform.downloadTitle, symbol: added ? "checkmark" : "arrow.down")
                    }.buttonStyle(.plain).disabled(added).opacity(added ? 0.65 : 1).accessibilityIdentifier("downloadFile")
                    NavigationLink { NASDownloadsView(manager: app.downloads, owner: owner) } label: {
                        HStack { Text("查看下载任务"); Spacer(); Image(systemName: "arrow.right") }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }.accessibilityIdentifier("detailDownloads")
                    Text("下载期间请保持 App 在前台。下载完成后，可在“已下载”中选择保存位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }.background(NASStyle.canvas)
            .navigationTitle("文件详情").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $video) { selection in VideoPlaybackView(selection: selection, client: client) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }
}

struct NASDownloadsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var manager: NASDownloadManager
    let owner: String
    @State private var completed = false
    @State private var export: ExportFile?
    @State private var exported = false
    @State private var video: VideoSelection?
    @State private var remove: NASDownload?
    @State private var connection = false
    private var records: [NASDownload] { manager.records.filter { $0.owner == owner && ($0.state == .completed) == completed } }
    var body: some View {
        List {
            Section {
                Picker("下载列表", selection: $completed) {
                    Text("下载任务").tag(false); Text("已下载").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
            }.listRowBackground(Color.clear)
            if exported { Section { Label("已保存到所选位置", systemImage: "checkmark.circle").foregroundStyle(Theme.accent).accessibilityIdentifier("exportSuccess") } }
            if let error = manager.error { Section { ErrorBanner(message: error) } }
            if !completed {
                Section { Text("下载期间保持 App 在前台。中断后可从头重试；完成的文件可离线导出。").font(.footnote).foregroundStyle(.secondary) }
            }
            if records.isEmpty {
                ContentUnavailableView(completed ? "还没有已下载文件" : "没有下载任务", systemImage: "arrow.down.circle", description: Text(completed ? "任务完成后，在这里保存或分享文件。" : "进入群晖目录，选择一个文件开始下载。"))
            }
            ForEach(records) { item in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        NASFileRow(file: item.file)
                        HStack {
                            Text(item.state.title).font(.subheadline).accessibilityIdentifier("downloadState")
                            Spacer()
                            Text(progressText(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if item.state == .downloading {
                            if let expected = item.expected, expected > 0 { ProgressView(value: min(1, Double(item.received) / Double(expected))) }
                            else { ProgressView() }
                        }
                        if let message = item.message { Text(message).font(.footnote).foregroundStyle(.red) }
                        if item.state == .completed && item.file.isVideo {
                            Button { video = VideoSelection(file: item.file, owner: item.owner, localURL: manager.fileURL(item)) } label: { Label("播放已下载视频", systemImage: "play.circle") }.accessibilityIdentifier("playLocalVideo")
                        }
                        HStack(spacing: 20) {
                            if item.active { Button("取消") { manager.cancel(item.id) } }
                            else if item.state == .completed {
                                Button { exported = false; export = ExportFile(url: manager.fileURL(item)) } label: { Label(AppPlatform.isMac ? "另存为…" : "保存到文件", systemImage: "folder") }.accessibilityIdentifier("exportFile")
                                ShareLink(item: manager.fileURL(item)) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("用其他 App 打开或分享")
                                Spacer()
                                Button { remove = item } label: { Image(systemName: "trash") }.accessibilityLabel("删除本地副本")
                            } else {
                                Button("从头重试") {
                                    if let client = app.fileClient, owner == app.fileAccountID { manager.retry(item, client: client, owner: owner) }
                                    else { connection = true }
                                }
                                Button("移除记录") { remove = item }
                            }
                        }.font(.subheadline).buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
        }.scrollContentBackground(.hidden).background(NASStyle.canvas)
            .frame(maxWidth: AppPlatform.isMac ? 880 : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(NASStyle.canvas)
            .workspaceNavigationTitle("下载").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $video) { selection in VideoPlaybackView(selection: selection) }
            .sheet(item: $export) { item in FileExportSheet(url: item.url) { success in exported = success; export = nil } }
            .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .files) } }
            .confirmationDialog("移除此下载？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("移除本地副本和记录", role: .destructive) { if let remove { manager.remove(remove) }; remove = nil }
            } message: { Text("只移除本机的下载内容，群晖原文件保留。") }
    }
    private func progressText(_ item: NASDownload) -> String {
        let received = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        if let expected = item.expected { return received + " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) }
        return received
    }
}
private struct ExportFile: Identifiable { let id = UUID(); let url: URL }
struct FileExportSheet: UIViewControllerRepresentable {
    let url: URL
    var completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}


/// Subtle type colours make files scannable without competing with their names.
struct StorageFileBadge: View {
    let name: String
    let symbol: String
    let folder: Bool
    var expanded = false
    private var suffix: String { String(name.split(separator: ".").last ?? "FILE").uppercased() }
    private var color: Color {
        if folder { return NASStyle.accent }
        switch suffix {
        case "JPG", "JPEG", "PNG", "HEIC", "GIF", "WEBP": return NASStyle.violet
        case "MP4", "MOV", "MKV", "M4V": return NASStyle.coral
        case "PDF", "TXT", "MD", "DOC", "DOCX": return NASStyle.blue
        default: return .secondary
        }
    }
    var body: some View {
        Group {
            if expanded {
                Image(systemName: symbol).font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity).frame(height: 82)
            } else {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical).frame(width: 42, height: 42)
            }
        }.foregroundStyle(color).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
