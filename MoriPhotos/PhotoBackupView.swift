import SwiftUI
import Photos

struct PhotoBackupView: View {
    @EnvironmentObject private var backup: PhotoBackupManager
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var wifiOnly = true
    @State private var choosingFolder = false
    var body: some View {
        Form {
            Section {
                Toggle("自动备份新照片", isOn: Binding(get: { backup.configuration.enabled }, set: { enabled in
                    if enabled { Task { await backup.enable(folder: backup.configuration.folder, wifiOnly: wifiOnly) } }
                    else { backup.disable() }
                })).accessibilityIdentifier("enableNewPhotoBackup").disabled(backup.preparing)
                if backup.preparing { Label("正在检查备份位置…", systemImage: "network") }
                LabeledContent("当前状态", value: backup.status).accessibilityIdentifier("photoBackupStatus")
                if backup.configuration.enabled {
                    LabeledContent("已备份", value: "\(backup.ledger.completed.count) 张")
                    if backup.pendingCount > 0 { LabeledContent("待备份", value: "\(backup.pendingCount) 张") }
                    if let date = backup.ledger.lastCompletedAt { LabeledContent("上次完成", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button("立即检查新照片") { backup.checkNow() }.disabled(backup.running).accessibilityIdentifier("checkNewPhotoBackup")
                }
            } footer: {
                if let date = backup.configuration.startedAt {
                    Text("只备份 \(date.formatted(date: .abbreviated, time: .shortened)) 起的新照片，不回传更早的图库。关闭后重新开启同一位置，会补传期间的新照片。")
                } else { Text("首次开启后，只备份新拍摄的照片，不上传本机已有的照片。") }
            }
            if let error = backup.error { Section { ErrorBanner(message: error) } }
            Section {
                Button { backup.clearFolderError(); choosingFolder = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("选择备份文件夹").foregroundStyle(.primary)
                            Text(backup.configuration.folder).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).accessibilityIdentifier("photoBackupFolder")
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 3)
                }.accessibilityIdentifier("chooseBackupFolder").disabled(backup.preparing)
                NavigationLink("File Station 连接设置") { ConnectionView(service: .files) }
            } header: { Text("备份位置") } footer: {
                Text("点上方文件夹即可浏览群晖目录并选择，无需输入路径。新照片按年/月归档；更换位置后从选择时开始备份，旧备份留在原目录。")
            }
            Section {
                Toggle("仅 Wi-Fi 备份", isOn: $wifiOnly).disabled(backup.configuration.enabled || backup.preparing)
                LabeledContent("照片权限", value: library.authorization == .authorized ? "全部照片" : "需要全部照片")
                if library.authorization != .authorized {
                    if library.authorization == .notDetermined {
                        Button("允许访问照片") { Task { await library.requestAccess() } }
                    } else {
                        Button("打开系统权限设置") { AppPlatform.openPhotoSettings() }
                    }
                }
            } footer: {
                Text("保存静态原图与 Live Photo 的原始视频，不压缩、不删除本机照片。跳过截图和独立视频；新保存或同步到本机、且拍摄时间在开启之后的图片也可能纳入备份。")
            }
            Section(AppPlatform.isMac ? "Mac 备份运行方式" : "后台备份") {
                Text(AppPlatform.isMac ? "森空间运行时会检查 Mac 照片图库并备份新照片，切换到其他窗口也可继续。退出 App 或 Mac 休眠后暂停，下次打开会补传；这里读取的是 Mac 图库，手机照片需由手机端备份或先同步到 Mac。" : "打开森空间时自动检查并补传；后台由 iOS 安排运行，无法保证拍照后立即上传。系统中关闭后台 App 刷新、低电量或强制退出 App 时，可能要等下次打开才能继续。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("断网会保留备份记录并稍后重试。每个原始文件通过 NAS 大小与内容校验后，才记为已备份；同名但内容不同的文件不会被覆盖。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .workspaceNavigationTitle("新照片备份").navigationBarTitleDisplayMode(.inline)
        .onAppear { wifiOnly = backup.configuration.wifiOnly }
        .sheet(isPresented: $choosingFolder) {
            NavigationStack {
                BackupFolderPicker(path: nil, onSelect: { selected, owner in
                    if await backup.selectFolder(selected, owner: owner) { choosingFolder = false }
                }, onCancel: { choosingFolder = false })
            }
                .desktopSheet(width: 660, height: 580)
                .environmentObject(app)
                .environmentObject(backup)
                .interactiveDismissDisabled(backup.preparing)
        }
    }
}

private struct BackupFolderPicker: View {
    let path: String?
    let onSelect: (String, String) async -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var backup: PhotoBackupManager
    @StateObject private var store = NASFileBrowserStore()
    @State private var loadedOwner: String?
    @State private var connecting = false
    @State private var connectionMessage: String?
    private var selectable: Bool { path != nil && loadedOwner == app.fileAccountID && app.fileClient != nil && store.error == nil && !store.loading && !connecting && !backup.preparing }
    var body: some View {
        List {
            if app.fileClient == nil {
                if connecting { Label("正在连接群晖…", systemImage: "network") }
                if let connectionMessage { ErrorBanner(message: connectionMessage) }
                NavigationLink("连接群晖文件服务") { ConnectionView(service: .files) }
                if !connecting { Button("重试连接") { Task { await load(retry: true) } } }
            } else {
                ForEach(store.items.filter(\.isdir)) { folder in
                    NavigationLink {
                        BackupFolderPicker(path: folder.path, onSelect: onSelect, onCancel: onCancel)
                    } label: {
                        Label(folder.name, systemImage: "folder.fill").padding(.vertical, 5)
                    }.accessibilityIdentifier("backupFolder_" + folder.name)
                }
                if store.hasMore {
                    Button("加载更多目录") { Task { if let client = app.fileClient { await store.loadMore(client: client, path: path, sort: .name, ascending: true, foldersOnly: true) } } }.disabled(store.loading)
                }
                if store.loading { ProgressView() }
                if let error = store.error { ErrorBanner(message: error) }
                if store.items.isEmpty && !store.loading && store.error == nil {
                    Text(path == nil ? "没有可访问的共享文件夹" : "这个文件夹没有子文件夹，可以直接选用")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = backup.folderError { ErrorBanner(message: error) }
                Text(path ?? "先点选一个共享文件夹")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).accessibilityIdentifier("backupPickerPath")
                Button {
                    if let path, let owner = loadedOwner { Task { await onSelect(path, owner) } }
                } label: {
                    HStack {
                        Spacer()
                        if backup.preparing { ProgressView() }
                        Text(backup.preparing ? "正在检查写入权限…" : "选用此文件夹")
                        Spacer()
                    }.padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).disabled(!selectable).accessibilityIdentifier("useBackupFolder")
            }.padding(16).frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .navigationTitle(path.map { ($0 as NSString).lastPathComponent } ?? "群晖文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消", action: onCancel).disabled(backup.preparing).accessibilityIdentifier("cancelBackupFolder") } }
        .disabled(backup.preparing)
        .task(id: app.fileConnectionID) { await load() }
        .refreshable { await load(retry: true) }
    }
    private func load(retry: Bool = false) async {
        connecting = true; loadedOwner = nil; connectionMessage = nil
        await app.restoreConnection(service: .files, retry: retry)
        guard !Task.isCancelled else { return }
        connecting = false
        if let client = app.fileClient {
            let owner = app.fileAccountID
            await store.reset(client: client, path: path, sort: .name, ascending: true, foldersOnly: true)
            if !Task.isCancelled, owner == app.fileAccountID, client === app.fileClient { loadedOwner = owner }
        } else {
            connectionMessage = app.restoreErrors[.files]
        }
    }
}
