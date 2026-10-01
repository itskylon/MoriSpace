import SwiftUI

/// A lightweight launch page. Shortcuts change destinations without resetting their navigation paths.
struct HomeOverviewView: View {
    var isActive = true
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var backup: PhotoBackupManager
    @EnvironmentObject private var calendar: CalendarStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detail: Detail?
    private enum Detail: String, Identifiable { case backup, downloads; var id: String { rawValue } }
    private var usesSidebar: Bool { AppPlatform.isMac || sizeClass == .regular }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 24 : 20) {
                    header
                    VStack(alignment: .leading, spacing: 12) {
                        MoriSectionHeading("存储入口")
                        shortcuts(wide: wide)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            device.frame(maxWidth: .infinity)
                            dailyTasks
                                .frame(width: min(geometry.size.width * 0.32, 340))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            MoriSectionHeading("设备概览")
                            device
                        }
                        dailyTasks
                    }
                }
                .padding(.horizontal, wide ? 28 : 20).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 1240).frame(maxWidth: .infinity, alignment: .top)
            }.phoneMenuScrolling(active: isActive).background(NASStyle.canvas)
        }
        .workspaceNavigationTitle("首页").navigationBarTitleDisplayMode(.inline)
        .toolbar(usesSidebar ? .automatic : .hidden, for: .navigationBar)
        .navigationDestination(item: $detail) { destination in
            Group {
                switch destination {
                case .backup: PhotoBackupView()
                case .downloads: NASDownloadsView(manager: app.downloads, owner: app.fileAccountID)
                }
            }.toolbar(.visible, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("森空间").font(.system(size: 30, weight: .bold)).accessibilityIdentifier("homeTitle")
                Text(Date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { open(.settings) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                    .frame(width: 44, height: 44).background(NASStyle.surface, in: Circle())
                    .overlay(Circle().stroke(NASStyle.outline, lineWidth: 0.5))
            }.buttonStyle(.plain).accessibilityLabel("设置")
        }
    }

    private func shortcuts(wide: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 12) {
            shortcut("本机照片", subtitle: library.canRead ? "\(library.assets.count) 张照片" : "浏览照片图库", icon: "photo.on.rectangle", color: NASStyle.accent, page: .local, id: "homeLocalPhotos")
            shortcut("群晖照片", subtitle: "个人与共享空间", icon: "photo.stack", color: .indigo, page: .photos, id: "homeNASPhotos")
            shortcut("群晖文件", subtitle: "文件夹与文档", icon: "folder", color: .orange, page: .files, id: "homeNASFiles")
            shortcut("OneDrive", subtitle: "云端文件", icon: "cloud", color: .blue, page: .oneDrive, id: "homeOneDrive")
        }
    }

    private func shortcut(_ title: String, subtitle: String, icon: String, color: Color, page: WorkspacePage, id: String) -> some View {
        Button { open(page) } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 23, weight: .regular)).foregroundStyle(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(spacing: 4) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, minHeight: 92).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private var dailyTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            MoriSectionHeading("日常")
            VStack(spacing: 0) {
                calendarCard
                Divider().padding(.leading, 60)
                backupCard
                Divider().padding(.leading, 60)
                downloadsCard
            }.homeSurface()
        }
    }
    private var device: some View {
        HomeDeviceCard(isActive: isActive && detail == nil) { open(.monitor) }.id(app.monitorConnectionID)
    }
    private var calendarCard: some View {
        HomeSummaryCard(title: "今日日程", value: Date().formatted(.dateTime.day().locale(Locale(identifier: "zh_Hans_CN"))),
                        subtitle: calendar.layout.lunarDate(on: Date()).description, icon: "calendar", color: .orange, id: "homeCalendar") {
            calendar.today(); open(.calendar)
        }
    }
    private var backupCard: some View {
        HomeSummaryCard(title: "照片备份", value: backup.configuration.enabled ? (backup.running ? "备份中" : "已开启") : "未开启",
                        subtitle: backup.error != nil ? "备份需要检查" : (backup.configuration.enabled ? "已备份 \(backup.ledger.completed.count) 张" : "自动备份新拍照片"),
                        icon: "icloud.and.arrow.up", color: NASStyle.accent, id: "homeBackup") { openDetail(.backup) }
    }
    private var downloadsCard: some View {
        HomeDownloadsCard(manager: app.downloads, owner: app.fileAccountID) { openDetail(.downloads) }
    }
    private func openDetail(_ destination: Detail) {
        if usesSidebar { open(destination == .backup ? .backup : .downloads) }
        else { detail = destination }
    }
    private func open(_ page: WorkspacePage) {
        if usesSidebar { navigation.selection = page; return }
        switch page {
        case .photos, .files, .monitor:
            navigation.storageUsesOneDrive = false
            navigation.storageSection = page == .photos ? "照片" : page == .files ? "文件" : "状态"
            navigation.phoneSelection = .photos
        case .oneDrive:
            navigation.storageUsesOneDrive = true; navigation.phoneSelection = .photos
        default: navigation.phoneSelection = page
        }
    }
}

private struct HomeDeviceCard: View {
    var isActive: Bool
    var open: () -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = NASMonitorStore()
    private var snapshot: NASMonitorSnapshot? { app.monitorClient == nil ? nil : store.snapshot }
    private var status: String {
        if app.restoreErrors[.monitor] != nil { return "连接需要检查" }
        guard let snapshot else {
            return app.restoringService == .monitor || app.monitorClient != nil ? "正在读取" : "尚未连接"
        }
        if !snapshot.hasData { return "暂时无法读取" }
        if snapshot.hasAttention { return snapshot.issues.isEmpty ? "有项目需关注" : "有项目需关注 · 部分信息不可用" }
        return snapshot.issues.isEmpty ? "运行正常" : "部分信息不可用"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive").font(.system(size: 26)).foregroundStyle(NASStyle.accent)
                        .frame(width: 46, height: 46).background(NASStyle.selection, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot?.system?.model ?? "群晖 NAS").font(.headline).foregroundStyle(.primary)
                        Text(snapshot?.system?.version ?? "设备运行状态").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("homeDevice")
            HStack(spacing: 6) {
                Circle().fill(snapshot?.hasData == true && snapshot?.hasAttention == false && snapshot?.issues.isEmpty == true ? NASStyle.accent : .secondary).frame(width: 6, height: 6)
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("homeNASStatus")
                Spacer(minLength: 0)
                Text(snapshot.map { $0.updatedAt.formatted(date: .omitted, time: .shortened) + " 更新" } ?? "等待读取")
                    .font(.caption2).foregroundStyle(.tertiary).accessibilityIdentifier("homeUpdated")
            }
            HStack(spacing: 0) {
                metric("CPU", value: NASMonitorFormat.percent(snapshot?.resources?.cpu), id: "homeCPU")
                Divider().frame(height: 38)
                metric("内存", value: NASMonitorFormat.percent(snapshot?.resources?.memory), id: "homeMemory")
                Divider().frame(height: 38)
                metric("温度", value: snapshot?.system?.temperature.map { String(format: "%.0f°", $0) } ?? "—", id: "homeTemperature")
            }.padding(.vertical, 3)
            if let volumes = snapshot?.storage?.volumes, !volumes.isEmpty {
                Divider()
                ForEach(volumes.prefix(2)) { volume in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).foregroundStyle(.secondary)
                            Spacer()
                            Text(NASMonitorFormat.bytes(volume.used) + " / " + NASMonitorFormat.bytes(volume.total))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption2)
                        if let fraction = volume.fraction {
                            ProgressView(value: fraction).tint(volume.lowSpace || volume.health == .critical ? .orange : NASStyle.accent)
                        }
                    }
                }
            } else {
                Text(snapshot?.hasData == true ? "存储容量暂不可用" : "连接后查看负载、温度与存储容量")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).homeSurface()
        .task(id: "\(isActive)-\(scenePhase)") {
            guard isActive && scenePhase == .active else { store.stop(); return }
            await app.restoreConnection(service: .monitor)
            guard !Task.isCancelled, let client = app.monitorClient else { return }
            store.start(client: client, automatic: true)
        }
        .onDisappear { store.stop() }
    }
    private func metric(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct HomeDownloadsCard: View {
    @ObservedObject var manager: NASDownloadManager
    let owner: String
    let open: () -> Void
    var body: some View {
        let records = manager.records.filter { $0.owner == owner }
        let active = records.filter(\.active).count
        HomeSummaryCard(title: "群晖下载", value: active > 0 ? "\(active) 项进行中" : "\(records.filter { $0.state == .completed }.count) 个文件",
                        subtitle: "查看本机下载", icon: "arrow.down.circle", color: .blue, id: "homeDownloads", open: open)
    }
}

private struct HomeSummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let id: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
                    .frame(width: 34, height: 34).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 72).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

private extension View {
    func homeSurface() -> some View {
        background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(NASStyle.outline, lineWidth: 0.5) }
    }
}
