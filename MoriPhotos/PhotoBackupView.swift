import SwiftUI
import Photos

struct PhotoBackupView: View {
    @EnvironmentObject private var backup: PhotoBackupManager
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var wifiOnly = true
    @State private var choosingFolder = false
    @State private var showDetails = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 20) {
                                overview
                                if let error = backup.error { ErrorBanner(message: error) }
                                backupDetails
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 20) {
                                destination
                                preferences
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            overview
                            if let error = backup.error { ErrorBanner(message: error) }
                            destination
                            preferences
                            backupDetails
                        }
                    }
                }
                .padding(AppPlatform.isMac ? 28 : 20)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity, alignment: .top)
            }.phoneMenuScrolling().background(NASStyle.canvas)
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
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(get: { backup.configuration.enabled }, set: { enabled in
                if enabled { Task { await backup.enable(folder: backup.configuration.folder, wifiOnly: wifiOnly) } }
                else { backup.disable() }
            })) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("自动备份新照片").font(.headline).foregroundStyle(.primary)
                    Text(backup.configuration.enabled ? "已开启，保留本机原图" : "将新拍照片保存到 NAS").font(.caption).foregroundStyle(.secondary)
                }
            }.tint(NASStyle.accent).frame(minHeight: 44).accessibilityIdentifier("enableNewPhotoBackup").disabled(backup.preparing)

            panelRule
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if backup.preparing || backup.running { ProgressView().controlSize(.small).tint(NASStyle.accent) }
                    else { Image(systemName: backup.error != nil ? "exclamationmark.circle" : backup.configuration.enabled ? "checkmark.circle" : "pause.circle")
                        .foregroundStyle(backup.error != nil ? NASStyle.coral : NASStyle.accent) }
                }.frame(width: 28, height: 28)
                Text(backup.preparing ? "正在检查备份位置…" : backup.status)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary).accessibilityIdentifier("photoBackupStatus")
            }

            if backup.configuration.enabled {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        backupMetric("已备份", value: backup.ledger.completed.count)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(NASStyle.outline).frame(width: 1, height: 52)
                        backupMetric("待备份", value: backup.pendingCount)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        backupMetric("已备份", value: backup.ledger.completed.count)
                        backupMetric("待备份", value: backup.pendingCount)
                    }
                }.padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 10) {
                    checkButton
                    lastBackupTime
                }
            }
            Text(backup.configuration.startedAt.map { "从 \($0.formatted(date: .abbreviated, time: .shortened)) 起备份新照片。" } ?? "开启后从新照片开始，本机已有照片不会上传。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).backupPanel()
    }

    private var panelRule: some View { Rectangle().fill(NASStyle.outline).frame(height: 1) }

    private var checkButton: some View {
        Button { backup.checkNow() } label: {
            Label("立即检查新照片", systemImage: "arrow.clockwise").font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(backup.running).accessibilityIdentifier("checkNewPhotoBackup")
    }

    @ViewBuilder private var lastBackupTime: some View {
        if let date = backup.ledger.lastCompletedAt {
            Text("上次完成 \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func backupMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(size: 34, weight: .semibold)).monospacedDigit().foregroundStyle(.primary).fixedSize()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("备份位置").font(.headline)
                Spacer(minLength: 8)
                Text("NAS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Button { backup.clearFolderError(); choosingFolder = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(NASStyle.accent)
                        .frame(width: 42, height: 42).background(NASStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("选择备份文件夹").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(backup.configuration.folder).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).truncationMode(.middle).accessibilityIdentifier("photoBackupFolder")
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chooseBackupFolder").disabled(backup.preparing)
            Text("照片按年 / 月归档，点目录可更换位置。")
                .font(.caption).foregroundStyle(.secondary)
            panelRule
            NavigationLink { ConnectionView(service: .files) } label: {
                HStack {
                    Text("File Station 连接设置").font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(NASStyle.accent)
        }.backupPanel()
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备份偏好").font(.headline)
            Toggle("仅 Wi-Fi 备份", isOn: $wifiOnly).font(.subheadline).frame(minHeight: 44).disabled(backup.configuration.enabled || backup.preparing)
            if backup.configuration.enabled {
                Text("关闭自动备份后可修改网络偏好。").font(.caption).foregroundStyle(.secondary)
            }
            panelRule
            HStack {
                Label("照片权限", systemImage: "photo").font(.subheadline)
                Spacer()
                Text(library.authorization == .authorized ? "全部照片" : "需要全部照片")
                    .font(.caption).foregroundStyle(library.authorization == .authorized ? Color.secondary : .orange)
            }
            if library.authorization != .authorized {
                if library.authorization == .notDetermined {
                    Button("允许访问照片") { Task { await library.requestAccess() } }.font(.subheadline).frame(minHeight: 44)
                } else {
                    Button("打开系统权限设置") { AppPlatform.openPhotoSettings() }.font(.subheadline).frame(minHeight: 44)
                }
            }
        }.backupPanel()
    }

    private var backupDetails: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("保存静态原图与 Live Photo 的原始视频，不压缩、不删除本机照片。跳过截图和独立视频；新保存或同步到本机、且拍摄时间在开启之后的图片也可能纳入备份。")
                Text("关闭后重新开启同一位置，会补传期间的新照片。更换位置后从选择时开始备份，旧备份留在原目录。")
                Text(AppPlatform.isMac ? "森空间运行时检查 Mac 照片图库，切换到其他窗口也可继续。退出 App 或 Mac 休眠后暂停，下次打开会补传。手机照片需由手机端备份，或先同步到 Mac 图库。" : "打开森空间时自动检查并补传；后台由 iOS 安排运行，无法保证拍照后立即上传。关闭后台 App 刷新、低电量或强制退出 App 时，可能要等下次打开才能继续。")
                Text("断网会保留备份记录并稍后重试。每个原始文件通过 NAS 大小与内容校验后，才记为已备份；同名但内容不同的文件不会被覆盖。")
            }.font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
        } label: { Text("备份范围与运行方式").frame(minHeight: 44) }
        .font(.subheadline).tint(.secondary)
        .backupPanel()
    }
}

private extension View {
    func backupPanel() -> some View {
        padding(18).background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(NASStyle.outline, lineWidth: 0.5) }
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
        }.phoneMenuScrolling()
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
