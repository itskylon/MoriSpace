import SwiftUI
import QuickLook

/// The cloud browser owns its navigation. Drive file IDs are opaque and must never
/// be interpreted as filesystem paths or mixed with a NAS directory history.
@MainActor
struct GoogleDriveHomeView: View {
    var isActive = true
    @EnvironmentObject private var auth: GoogleDriveAuth
    @EnvironmentObject private var downloads: GoogleDriveDownloads
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var interactionEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var folders: [GoogleDriveFile] = []
    @State private var query = ""
    @State private var items: [GoogleDriveFile] = []
    @State private var nextPage: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var refreshID = UUID()
    @State private var loadedKey: RequestKey?
    @State private var moreTask: Task<Void, Never>?
    @State private var selected: GoogleDriveFile?
    @State private var showingDownloads = false
    @State private var disconnecting = false
    @State private var downloadNotice: String?
    @State private var folderCache: [String: FolderSnapshot] = [:]
    @State private var visibleRow: String?
    @State private var scrollRestore: String?
    @State private var scrollRestoreID = UUID()
    @State private var listSpace = UUID()
    @State private var backDistance: CGFloat = 0
    @FocusState private var searchFocused: Bool

    private struct RequestKey: Hashable {
        let owner: String?
        let folder: String
        let search: String
        let active: Bool
        let refresh: UUID
    }
    private struct FolderSnapshot {
        let files: [GoogleDriveFile]
        let nextPage: String?
        let firstVisible: String?
        let refresh: UUID
    }
    private var canGoUp: Bool { auth.accountID != nil && !folders.isEmpty && search.isEmpty }
    private var edgeBackEnabled: Bool {
        isActive && interactionEnabled && scenePhase == .active && !wide && canGoUp
            && selected == nil && !showingDownloads && !disconnecting
    }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentFolder: String { folders.last?.id ?? "root" }
    private var requestKey: RequestKey {
        RequestKey(owner: auth.accountID, folder: search.isEmpty ? currentFolder : "root", search: search, active: isActive, refresh: refreshID)
    }
    private var visibleItems: [GoogleDriveFile] { loadedKey == requestKey ? items : [] }
    private var wide: Bool { AppPlatform.isMac || sizeClass == .regular }
    private var accountLabel: String { auth.email ?? auth.accountName ?? "Google 账号" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(NASStyle.outline).frame(height: 0.5)
            if auth.accountID != nil { browser }
            else { connection }
        }
        .background(NASStyle.canvas)
        .workspaceNavigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isActive) { if isActive { await auth.restore() } }
        .task(id: requestKey) { await reset(requestKey) }
        .onChange(of: auth.accountID) { _, _ in
            folders = []; query = ""; selected = nil; downloadNotice = nil
            folderCache = [:]; visibleRow = nil; backDistance = 0
            moreTask?.cancel(); moreTask = nil
        }
        .onChange(of: isActive) { _, active in if !active { searchFocused = false; backDistance = 0 } }
        .onDisappear { moreTask?.cancel(); moreTask = nil; searchFocused = false }
        .sheet(isPresented: $showingDownloads) {
            NavigationStack { GoogleDriveDownloadsView(owner: auth.accountID ?? "") }
                .desktopSheet(width: 800, height: 620)
        }
        .confirmationDialog(selected?.name ?? "文件", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let file = selected {
                if file.canDownload {
                    Button(file.exportFormat.map { "下载为 \($0.fileExtension.uppercased())" } ?? AppPlatform.downloadTitle) { enqueue(file) }
                } else { Button("此文件不允许下载") {}.disabled(true) }
                if let url = googleDriveWebURL(file.id) { Link("在 Google Drive 中查看", destination: url) }
                Button("取消", role: .cancel) { selected = nil }
            }
        }
        .confirmationDialog("断开 Google Drive？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                if let owner = auth.accountID { downloads.cancelActive(owner: owner) }
                auth.signOut()
            }
            Button("取消", role: .cancel) {}
        } message: { Text("正在下载的任务会取消，已下载的本机文件会保留。") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(NASStyle.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Google Drive").font(.title3.weight(.bold))
                Text(auth.accountID == nil ? "云端文件" : accountLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).accessibilityIdentifier("googleDriveAccount")
            }
            Spacer(minLength: 8)
            Button { searchFocused = false; showingDownloads = true } label: {
                Image(systemName: "arrow.down.circle").font(.system(size: 21)).frame(width: 44, height: 44)
            }.buttonStyle(MoriPressStyle()).accessibilityLabel("Google Drive 下载")
                .accessibilityIdentifier("googleDriveDownloads")
            if auth.accountID != nil {
                Menu {
                    Text(accountLabel)
                    Button("刷新目录", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    Button("断开连接", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { disconnecting = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel("Google Drive 账号选项").accessibilityIdentifier("googleDriveAccountMenu")
            }
        }.padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 9)
    }

    private var connection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接你的云端文件").font(.title2.weight(.bold)).tracking(-0.5)
                    Text("使用 Google 官方登录，浏览文件夹并将需要的文件下载到本机。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = auth.error { ErrorBanner(message: error).accessibilityIdentifier("googleDriveAuthError") }
                if auth.isRestoring { ProgressView("正在恢复 Google Drive 连接…") }
                if auth.isConfigured {
                    Button { Task { await auth.signIn() } } label: {
                        HStack(spacing: 10) {
                            if auth.isAuthorizing { ProgressView().tint(NASStyle.ink) }
                            Text(auth.isAuthorizing ? "正在等待 Google 授权…" : "使用 Google 账号连接").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                        }.foregroundStyle(NASStyle.ink).padding(16)
                            .background(NASStyle.lime, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(MoriPressStyle(scale: 0.965))
                        .disabled(auth.isAuthorizing || auth.isRestoring)
                        .accessibilityIdentifier("connectGoogleDrive")
                    Text("授权在 Google 页面完成；森空间不会读取或保存你的 Google 密码。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Google 登录尚未配置", systemImage: "key.horizontal").font(.subheadline.weight(.semibold))
                        Text("需要先为森空间配置 Google OAuth 应用。浏览器已登录 Google，并不代表 App 已获得云盘访问授权。")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link("打开 Google Cloud 应用凭据", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("googleDriveSetupLink")
                    }.padding(16).background(NASStyle.inset, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("googleDriveNeedsConfiguration")
                }
            }.padding(24).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
        }.phoneMenuScrolling(active: isActive)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索整个 Google Drive", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searchFocused)
                        .onSubmit { searchFocused = false }
                        .accessibilityIdentifier("googleDriveSearch")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 30, height: 36) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(NASStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                if search.isEmpty {
                    HStack(spacing: 8) {
                        if canGoUp {
                            Button { goUp() } label: {
                                Image(systemName: "chevron.backward").font(.body.weight(.semibold)).frame(width: 44, height: 36)
                                    .background(NASStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(MoriPressStyle()).accessibilityLabel("上一级")
                                .accessibilityIdentifier("googleDriveUp")
                                .keyboardShortcut("[", modifiers: .command)
                        }
                        breadcrumbs
                    }
                }
                else {
                    HStack {
                        Text("全部云端文件中的搜索结果").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(visibleItems.count) 项").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("googleDriveSearchScope")
                }
                if let notice = downloadNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(NASStyle.accent)
                        Text(notice).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("查看") { showingDownloads = true }
                    }.font(.caption).accessibilityIdentifier("googleDriveDownloadNotice")
                }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(NASStyle.outline).frame(height: 0.5)
            ScrollViewReader { scroll in
              List {
                if let error, loadedKey == requestKey {
                    VStack(alignment: .leading, spacing: 12) {
                        ErrorBanner(message: error)
                        Button("重试读取") {
                            if !visibleItems.isEmpty && nextPage != nil {
                                moreTask?.cancel(); moreTask = Task { await loadMore() }
                            } else { refreshID = UUID() }
                        }.accessibilityIdentifier("googleDriveRetry")
                    }.listRowSeparator(.hidden)
                }
                ForEach(visibleItems) { file in
                    Button { open(file) } label: { GoogleDriveFileRow(file: file, wide: wide, accessible: typeSize.isAccessibilitySize) }
                        .buttonStyle(MoriPressStyle(scale: 0.98))
                        .accessibilityIdentifier("googleDriveFile_" + file.id)
                        .id(file.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: DriveVisibleRows.self,
                                                       value: [file.id: geometry.frame(in: .named(listSpace)).minY])
                            }
                        }
                }
                if loading || loadingMore {
                    HStack { Spacer(); ProgressView(loadingMore ? "正在载入更多…" : "正在读取 Google Drive…"); Spacer() }
                        .padding(.vertical, 24).listRowSeparator(.hidden).accessibilityIdentifier("googleDriveLoading")
                } else if nextPage != nil && error == nil && loadedKey == requestKey {
                    Button("载入更多文件") {
                        moreTask?.cancel()
                        moreTask = Task { await loadMore() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 10).accessibilityIdentifier("googleDriveLoadMore")
                } else if visibleItems.isEmpty && error == nil {
                    ContentUnavailableView(search.isEmpty ? "这是一个空文件夹" : "没有找到匹配的文件", systemImage: search.isEmpty ? "folder" : "magnifyingglass", description: Text(search.isEmpty ? "可以返回上级继续浏览。" : "试试其他名称，或清除搜索继续浏览文件夹。"))
                        .listRowSeparator(.hidden).accessibilityIdentifier("googleDriveEmpty")
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .coordinateSpace(name: listSpace)
                .listRowSpacing(0).phoneMenuScrolling(active: isActive)
                .refreshable { await reset(requestKey, debounce: false, useCache: false) }
                .onPreferenceChange(DriveVisibleRows.self) { positions in
                    guard loadedKey == requestKey, !loading, scrollRestore == nil else { return }
                    visibleRow = positions.filter { $0.value >= -1 }.min { $0.value < $1.value }?.key
                }
                .task(id: scrollRestoreID) {
                    guard let target = scrollRestore else { return }
                    await Task.yield()
                    guard !Task.isCancelled, loadedKey == requestKey, visibleItems.contains(where: { $0.id == target }) else { return }
                    scroll.scrollTo(target, anchor: .top)
                    scrollRestore = nil
                }
                .background {
                    DriveBackGesture(enabled: edgeBackEnabled, rightToLeft: layoutDirection == .rightToLeft,
                                     progress: { backDistance = $0 }, finish: { completed in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) { backDistance = 0 }
                        if completed && edgeBackEnabled { goUp() }
                    })
                }
                .offset(x: reduceMotion ? 0 : min(54, backDistance * 0.18) * (layoutDirection == .rightToLeft ? -1 : 1))
                .overlay(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
                    if backDistance > 0 {
                        Image(systemName: "chevron.backward").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(NASStyle.signal, in: Circle())
                            .scaleEffect(reduceMotion ? 1 : min(1.15, 0.8 + backDistance / 400))
                            .opacity(min(1, backDistance / 45)).padding(8).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { navigate(to: -1) } label: { Label("我的云端硬盘", systemImage: "house") }
                    .accessibilityIdentifier("googleDriveRoot")
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Button(folder.name) { navigate(to: index) }.lineLimit(1)
                        .accessibilityIdentifier("googleDriveBreadcrumb_" + folder.id)
                }
            }.font(.subheadline.weight(.medium)).buttonStyle(.plain).frame(minHeight: 32)
                .foregroundStyle(.primary)
        }.accessibilityLabel("当前位置")
    }

    private func open(_ file: GoogleDriveFile) {
        searchFocused = false
        if file.isFolder {
            if search.isEmpty { folders.append(file) }
            else { folders = [file]; query = "" }
            downloadNotice = nil
        } else { selected = file }
    }
    private func navigate(to index: Int) {
        searchFocused = false; query = ""; downloadNotice = nil
        folders = index < 0 ? [] : Array(folders.prefix(index + 1))
    }
    private func goUp() {
        guard canGoUp else { return }
        navigate(to: folders.count - 2)
    }
    private func enqueue(_ file: GoogleDriveFile) {
        guard let owner = auth.accountID, loadedKey?.owner == owner else { return }
        downloads.enqueue(file, owner: owner, client: GoogleDriveClient(auth: auth))
        selected = nil
        if downloads.records.contains(where: { $0.owner == owner && $0.file.id == file.id && $0.active }) {
            downloadNotice = "已加入下载：" + file.name
        } else {
            downloadNotice = nil
            error = downloads.error ?? "暂时无法创建下载任务，请重试。"
        }
    }
    private func reset(_ key: RequestKey, debounce: Bool = true, useCache: Bool = true) async {
        moreTask?.cancel(); moreTask = nil
        if let previous = loadedKey, previous.owner == auth.accountID, previous.search.isEmpty,
           !loading, error == nil, previous.active {
            folderCache[previous.folder] = FolderSnapshot(files: items, nextPage: nextPage, firstVisible: visibleRow, refresh: previous.refresh)
            if folderCache.count > 20, let oldest = folderCache.keys.first(where: { $0 != previous.folder && $0 != key.folder }) {
                folderCache[oldest] = nil
            }
        }
        let ticket = UUID(); generation = ticket; loadedKey = key
        items = []; nextPage = nil; error = nil; loadingMore = false; loading = false
        visibleRow = nil; scrollRestore = nil
        guard key.active, let owner = key.owner, owner == auth.accountID else { return }
        if useCache, key.search.isEmpty, let snapshot = folderCache[key.folder], snapshot.refresh == key.refresh {
            items = snapshot.files; nextPage = snapshot.nextPage
            visibleRow = snapshot.firstVisible; scrollRestore = snapshot.firstVisible; scrollRestoreID = UUID()
            return
        }
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            if debounce && !key.search.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let page = try await GoogleDriveClient(auth: auth).list(folderID: key.folder, search: key.search)
            try Task.checkCancellation()
            guard generation == ticket, auth.accountID == owner else { return }
            var seen = Set<String>()
            items = page.files.filter { seen.insert($0.id).inserted }
            nextPage = page.nextPageToken
        } catch {
            guard generation == ticket, auth.accountID == owner, !Task.isCancelled else { return }
            self.error = googleDriveErrorMessage(error)
        }
    }
    private func loadMore() async {
        guard loadedKey == requestKey, !loading, !loadingMore, let token = nextPage, let owner = auth.accountID else { return }
        let ticket = generation, key = requestKey
        loadingMore = true; error = nil
        defer { if generation == ticket { loadingMore = false } }
        do {
            let page = try await GoogleDriveClient(auth: auth).list(folderID: key.folder, search: key.search, pageToken: token)
            try Task.checkCancellation()
            guard generation == ticket, auth.accountID == owner else { return }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.files.filter { seen.insert($0.id).inserted })
            // A repeated token would otherwise leave an endless load-more control.
            nextPage = page.nextPageToken == token ? nil : page.nextPageToken
        } catch {
            guard generation == ticket, auth.accountID == owner, !Task.isCancelled else { return }
            self.error = googleDriveErrorMessage(error)
        }
    }
}

private struct DriveVisibleRows: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct GoogleDriveFileRow: View {
    let file: GoogleDriveFile
    var wide = false
    var accessible = false
    var body: some View {
        HStack(spacing: 13) {
            StorageFileBadge(name: file.name, symbol: file.symbol, folder: file.isFolder)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(accessible ? 3 : 2).truncationMode(.middle)
                if !wide || accessible { metadata.font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if wide && !accessible { metadata.font(.caption).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .trailing) }
            Image(systemName: file.isFolder ? "chevron.right" : "ellipsis")
                .font(.system(size: file.isFolder ? 11 : 18, weight: .semibold)).foregroundStyle(.tertiary)
                .frame(width: 20).accessibilityHidden(true)
        }.padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
    }
    @ViewBuilder private var metadata: some View {
        HStack(spacing: 7) {
            if file.isFolder { Text("文件夹") }
            else if let size = file.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).monospacedDigit() }
            else if let format = file.exportFormat { Text("Google 文档 · 导出 \(format.fileExtension.uppercased())") }
            if let modified = file.modifiedTime {
                Text(modified.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
            }
        }.lineLimit(1)
    }
}

@MainActor
private struct GoogleDriveDownloadsView: View {
    let owner: String
    @EnvironmentObject private var auth: GoogleDriveAuth
    @EnvironmentObject private var manager: GoogleDriveDownloads
    @Environment(\.dismiss) private var dismiss
    @State private var completed = false
    @State private var export: GoogleDriveLocalFile?
    @State private var preview: GoogleDriveLocalFile?
    @State private var removing: GoogleDriveDownload?
    @State private var exported = false
    private var records: [GoogleDriveDownload] {
        manager.records.filter { $0.owner == owner && ($0.state == .completed) == completed }
    }

    var body: some View {
        List {
            Picker("下载列表", selection: $completed) {
                Text("下载任务").tag(false)
                Text("已下载").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 360).listRowBackground(Color.clear)
                .accessibilityIdentifier("googleDriveDownloadsFilter")
            if exported { Label("已保存到所选位置", systemImage: "checkmark.circle").foregroundStyle(NASStyle.accent) }
            if let error = manager.error { ErrorBanner(message: error) }
            if !completed {
                Text("下载期间请保持 App 在前台。Google 文档会转换为可离线使用的文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if records.isEmpty {
                ContentUnavailableView(completed ? "还没有已下载文件" : "没有下载任务", systemImage: "arrow.down.circle", description: Text(completed ? "下载完成后，可在这里预览、保存或分享。" : "在 Google Drive 中选择一个文件开始下载。"))
            }
            ForEach(records) { record in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        GoogleDriveFileRow(file: record.file)
                        HStack {
                            Text(record.state.title).accessibilityIdentifier("googleDriveDownloadState")
                            Spacer()
                            Text(progress(record)).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption)
                        if record.state == .downloading {
                            if let expected = record.expected, expected > 0 {
                                ProgressView(value: min(1, max(0, Double(record.received) / Double(expected))))
                            } else { ProgressView() }
                        }
                        if let message = record.message { Text(message).font(.caption).foregroundStyle(.red) }
                        actions(record)
                    }.padding(.vertical, 4)
                }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NASStyle.canvas)
            .navigationTitle("Google Drive 下载").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $preview) { file in GoogleDriveLocalPreview(url: file.url).desktopSheet(width: 900, height: 650) }
            .sheet(item: $export) { file in FileExportSheet(url: file.url) { success in exported = success; export = nil } }
            .confirmationDialog("移除此下载？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除本机文件和记录", role: .destructive) { if let removing { manager.remove(removing) }; removing = nil }
                Button("取消", role: .cancel) { removing = nil }
            } message: { Text("Google Drive 上的原始文件会保留。") }
    }
    @ViewBuilder private func actions(_ record: GoogleDriveDownload) -> some View {
        HStack(spacing: 18) {
            if record.active {
                Button("取消") { manager.cancel(record.id) }
            } else if record.state == .completed {
                Button("预览", systemImage: "eye") { preview = GoogleDriveLocalFile(url: manager.fileURL(record)) }
                    .accessibilityIdentifier("googleDrivePreviewDownload")
                Button(AppPlatform.isMac ? "另存为…" : "保存到文件", systemImage: "folder") {
                    exported = false; export = GoogleDriveLocalFile(url: manager.fileURL(record))
                }.accessibilityIdentifier("googleDriveExportDownload")
                ShareLink(item: manager.fileURL(record)) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享已下载文件")
                Spacer(minLength: 0)
                removeButton(record)
            } else {
                Button("重新下载") {
                    guard auth.accountID == owner else { return }
                    manager.retry(record, client: GoogleDriveClient(auth: auth), owner: owner)
                }.disabled(auth.accountID != owner).accessibilityIdentifier("googleDriveRetryDownload")
                Spacer(minLength: 0)
                removeButton(record)
            }
        }.font(.subheadline).buttonStyle(.borderless)
    }
    private func removeButton(_ record: GoogleDriveDownload) -> some View {
        Button { removing = record } label: { Image(systemName: "trash") }
            .accessibilityLabel("移除本机下载记录")
    }
    private func progress(_ record: GoogleDriveDownload) -> String {
        let received = ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file)
        return record.expected.map { received + " / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? received
    }
}

private struct GoogleDriveLocalFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct GoogleDriveLocalPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    private var supported: Bool {
        #if targetEnvironment(macCatalyst)
        QLPreviewController.canPreviewItem(url as NSURL)
        #else
        QLPreviewController.canPreview(url as NSURL)
        #endif
    }
    var body: some View {
        NavigationStack {
            Group {
                if supported { GoogleDriveQuickLook(url: url).accessibilityIdentifier("googleDriveQuickLook") }
                else { ContentUnavailableView("此文件暂不支持预览", systemImage: "doc", description: Text("可返回下载列表，保存文件或用其他 App 打开。")) }
            }.navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

private struct GoogleDriveQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private func googleDriveWebURL(_ id: String) -> URL? {
    guard !id.isEmpty else { return nil }
    var components = URLComponents(string: "https://drive.google.com/open")
    components?.queryItems = [URLQueryItem(name: "id", value: id)]
    return components?.url
}

