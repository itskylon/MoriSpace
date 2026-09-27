import SwiftUI
import Photos

struct PhotoBackupView: View {
    @EnvironmentObject private var backup: PhotoBackupManager
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var wifiOnly = true
    @State private var choosingFolder = false
    @State private var showDetails = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overview
                    if let error = backup.error { ErrorBanner(message: error) }
                    let layout = geometry.size.width >= 800 ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                    layout {
                        destination.frame(maxWidth: .infinity, alignment: .topLeading)
                        preferences.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    backupDetails
                }
                .padding(AppPlatform.isMac ? 28 : 20)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity, alignment: .top)
            }.background(NASStyle.canvas)
        }
        .tint(NASStyle.accent)
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

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { backup.configuration.enabled }, set: { enabled in
                if enabled { Task { await backup.enable(folder: backup.configuration.folder, wifiOnly: wifiOnly) } }
                else { backup.disable() }
            })) {
                HStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(NASStyle.accent).frame(width: 46, height: 46)
                        .background(NASStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动备份新照片").font(.headline)
                        Text("将新的原始照片保存到群晖").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("enableNewPhotoBackup").disabled(backup.preparing)

            Divider()
            HStack(spacing: 8) {
                if backup.preparing || backup.running { ProgressView().controlSize(.small) }
                else { Circle().fill(backup.error != nil ? Color.orange : (backup.configuration.enabled ? NASStyle.accent : .secondary)).frame(width: 6, height: 6) }
                Text(backup.preparing ? "正在检查备份位置…" : backup.status)
                    .font(.subheadline.weight(.medium)).accessibilityIdentifier("photoBackupStatus")
            }

            if backup.configuration.enabled {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    backupMetric("已备份", value: backup.ledger.completed.count)
                    backupMetric("待备份", value: backup.pendingCount)
                    Spacer(minLength: 0)
                }
                if let date = backup.ledger.lastCompletedAt {
                    Text("上次完成 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { backup.checkNow() } label: {
                    Label("立即检查新照片", systemImage: "arrow.clockwise").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(backup.running).accessibilityIdentifier("checkNewPhotoBackup")
            }
            Text(backup.configuration.startedAt.map { "从 \($0.formatted(date: .abbreviated, time: .shortened)) 起备份新照片。" } ?? "开启后从新照片开始，本机已有照片不会上传。")
                .font(.caption).foregroundStyle(.secondary)
        }.backupPanel()
    }

    private func backupMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.formatted()).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                Text("张").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("备份位置").font(.subheadline.weight(.semibold))
            Button { backup.clearFolderError(); choosingFolder = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title3).foregroundStyle(NASStyle.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("选择备份文件夹").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(backup.configuration.folder).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).truncationMode(.middle).accessibilityIdentifier("photoBackupFolder")
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                    .background(NASStyle.canvas, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chooseBackupFolder").disabled(backup.preparing)
            Text("浏览群晖目录，选择保存位置。照片会按年 / 月归档。")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink { ConnectionView(service: .files) } label: {
                HStack {
                    Text("File Station 连接设置").font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption2)
                }.frame(minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(NASStyle.accent)
        }.backupPanel()
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("备份偏好").font(.subheadline.weight(.semibold))
            Toggle("仅 Wi-Fi 备份", isOn: $wifiOnly).font(.subheadline).disabled(backup.configuration.enabled || backup.preparing)
            if backup.configuration.enabled {
                Text("关闭自动备份后可修改网络偏好。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Label("照片权限", systemImage: "photo").font(.subheadline)
                Spacer()
                Text(library.authorization == .authorized ? "全部照片" : "需要全部照片")
                    .font(.caption).foregroundStyle(library.authorization == .authorized ? Color.secondary : .orange)
            }
            if library.authorization != .authorized {
                if library.authorization == .notDetermined {
                    Button("允许访问照片") { Task { await library.requestAccess() } }.font(.subheadline)
                } else {
                    Button("打开系统权限设置") { AppPlatform.openPhotoSettings() }.font(.subheadline)
                }
            }
        }.backupPanel()
    }

    private var backupDetails: some View {
        DisclosureGroup("备份范围与运行方式", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("保存静态原图与 Live Photo 的原始视频，不压缩、不删除本机照片。跳过截图和独立视频；新保存或同步到本机、且拍摄时间在开启之后的图片也可能纳入备份。")
                Text("关闭后重新开启同一位置，会补传期间的新照片。更换位置后从选择时开始备份，旧备份留在原目录。")
                Text(AppPlatform.isMac ? "森空间运行时检查 Mac 照片图库，切换到其他窗口也可继续。退出 App 或 Mac 休眠后暂停，下次打开会补传。手机照片需由手机端备份，或先同步到 Mac 图库。" : "打开森空间时自动检查并补传；后台由 iOS 安排运行，无法保证拍照后立即上传。关闭后台 App 刷新、低电量或强制退出 App 时，可能要等下次打开才能继续。")
                Text("断网会保留备份记录并稍后重试。每个原始文件通过 NAS 大小与内容校验后，才记为已备份；同名但内容不同的文件不会被覆盖。")
            }.font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
        }.font(.subheadline).tint(.secondary).padding(.horizontal, 4)
    }
}

private extension View {
    func backupPanel() -> some View {
        padding(18).background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
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
        .scrollContentBackground(.hidden)
        .background(NASStyle.canvas)
        .tint(NASStyle.accent)
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
