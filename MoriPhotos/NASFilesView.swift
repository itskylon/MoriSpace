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
                    VStack(alignment: .leading, spacing: 12) {
                        NASConnectionStatus(service: .files)
                        Button { connect = true } label: {
                            NASActionLabel(title: app.hasSavedConnection ? "文件连接设置" : "连接群晖文件", subtitle: "File Station", symbol: "folder")
                        }.buttonStyle(.plain).accessibilityIdentifier("connectFiles")
                        NavigationLink { NASDownloadsView(manager: app.downloads, owner: app.fileAccountID) } label: {
                            NASActionLabel(title: "下载", subtitle: "任务与离线文件", symbol: "arrow.down.circle")
                        }.buttonStyle(.plain).accessibilityIdentifier("openDownloads")
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }.background(NASStyle.canvas)
            }
        }.sheet(isPresented: $connect) { NavigationStack { ConnectionView(service: .files) } }
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
    private var sorting: String { sort.rawValue + String(ascending) }
    var body: some View {
        mobileBrowser
        .workspaceNavigationTitle(folder?.name ?? "群晖文件", detail: folder != nil).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink { NASDownloadsView(manager: app.downloads, owner: owner) } label: { Label("下载任务与已下载", systemImage: "arrow.down.circle") }.accessibilityIdentifier("openDownloads")
                        Picker("排序", selection: $sort) { ForEach(FileSort.allCases.filter { folder != nil || $0 != .size }) { Text($0.title).tag($0) } }
                        Toggle("升序排列", isOn: $ascending)
                        Button("文件连接设置") { connection = true }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.primary) }
                        .accessibilityLabel("文件选项").accessibilityIdentifier("fileOptions")
                }
            }
        }
        .task(id: sorting) { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected) { file in NavigationStack { NASFileDetailView(file: file, client: client, owner: owner) }.desktopSheet() }
        .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .files) }.desktopSheet() }
    }
    private var mobileBrowser: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let folder { Text(folder.path).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Text(folder == nil ? "共享文件夹" : "文件").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(store.items.count) / \(store.total) 项").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("fileCount")
                    }
                }.padding(.vertical, 4)
            }.listRowBackground(NASStyle.canvas).listRowSeparator(.hidden)
            if let error = store.error {
                Section {
                    ErrorBanner(message: error)
                    Button("重试读取") { Task { await refresh() } }
                }.listRowBackground(NASStyle.canvas)
            }
            Section {
                ForEach(store.items) { file in
                    if file.isdir {
                        if wideWorkspace {
                            NavigationLink(value: file) { NASFileRow(file: file) }.accessibilityIdentifier("nasFolder_" + file.name)
                        } else {
                            NavigationLink { NASFileBrowserView(client: client, owner: owner, folder: file) } label: { NASFileRow(file: file) }
                                .accessibilityIdentifier("nasFolder_" + file.name)
                        }
                    } else {
                        Button { selected = file } label: { NASFileRow(file: file) }
                            .buttonStyle(.plain).accessibilityIdentifier("nasFile_" + file.name)
                    }
                }
                if store.loading { HStack { Spacer(); ProgressView("正在读取文件…"); Spacer() }.padding() }
                else if store.hasMore && store.error == nil {
                    Button("载入更多") { Task { await store.loadMore(client: client, path: folder?.path, sort: sort, ascending: ascending) } }.accessibilityIdentifier("moreFiles")
                } else if store.items.isEmpty && store.error == nil {
                    ContentUnavailableView(folder == nil ? "没有可访问的共享文件夹" : "这是一个空文件夹", systemImage: "folder", description: Text(folder == nil ? "请检查账号的共享文件夹权限。" : "可以返回上级继续浏览。"))
                }
            }.listRowBackground(NASStyle.canvas)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(NASStyle.canvas)
    }
    private func refresh() async { await store.reset(client: client, path: folder?.path, sort: sort, ascending: ascending) }
}

struct NASFileRow: View {
    let file: NASFile
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: file.icon).font(.system(size: 20)).foregroundStyle(NASStyle.accent).frame(width: 36, height: 36)
                .background(NASStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 8) {
                    if !file.isdir, let size = file.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let date = file.modified { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
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
        List {
            Section { NASFileRow(file: file).padding(.vertical, 10) }
            Section("所在位置") { Text(file.path).font(.footnote).textSelection(.enabled) }
            if file.isVideo {
                Section {
                    Button { video = VideoSelection(file: file, owner: owner) } label: { Label("直接播放视频", systemImage: "play.circle.fill") }.accessibilityIdentifier("playVideo")
                } footer: { Text("支持本机可解码的 MP4、MOV 等视频。在线播放需要 NAS 支持分段读取。") }
            }
            Section {
                Button {
                    app.downloads.enqueue(file, owner: owner, client: client); added = true
                } label: {
                    Label(added ? "已加入下载队列" : AppPlatform.downloadTitle, systemImage: added ? "checkmark.circle" : "arrow.down.circle")
                }.disabled(added).accessibilityIdentifier("downloadFile")
                NavigationLink { NASDownloadsView(manager: app.downloads, owner: owner) } label: { Label("查看下载任务", systemImage: "list.bullet") }.accessibilityIdentifier("detailDownloads")
            } footer: { Text("下载期间请保持 App 在前台。下载完成后，可在“已下载”中选择保存位置。") }
        }.navigationTitle("文件详情").navigationBarTitleDisplayMode(.inline)
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
                }.pickerStyle(.segmented)
            }
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
        }.workspaceNavigationTitle("下载").navigationBarTitleDisplayMode(.inline)
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
