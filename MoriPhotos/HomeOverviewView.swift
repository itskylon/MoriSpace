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
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            device.frame(maxWidth: .infinity)
                            dailyTasks.frame(width: min(geometry.size.width * 0.34, 360))
                        }
                        storageShortcuts(wide: true)
                    } else {
                        device
                        storageShortcuts(wide: false)
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
                Text(AppBrand.name).font(.system(size: 25, weight: .semibold)).accessibilityIdentifier("homeTitle")
                Text(Date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { open(.settings) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                    .frame(width: 44, height: 44).background(NASStyle.surface, in: Circle())
                    .overlay(Circle().stroke(NASStyle.outline, lineWidth: 0.5))
            }.buttonStyle(.plain).accessibilityLabel("设置")
        }
    }

    private func storageShortcuts(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MoriSectionHeading("你的存储")
            shortcuts(wide: wide)
        }
    }
    private func shortcuts(wide: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : wide ? 3 : 2), spacing: 12) {
            shortcut("本机照片", subtitle: library.canRead ? "\(library.assets.count) 张照片" : "浏览照片图库", icon: "photo.on.rectangle", page: .local, id: "homeLocalPhotos")
            shortcut("群晖照片", subtitle: "个人与共享空间", icon: "photo.stack", page: .photos, id: "homeNASPhotos")
            shortcut("群晖文件", subtitle: "文件夹与文档", icon: "folder", page: .files, id: "homeNASFiles")
        }
    }

    private func shortcut(_ title: String, subtitle: String, icon: String, page: WorkspacePage, id: String) -> some View {
        Button { open(page) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular)).foregroundStyle(NASStyle.accent)
                    .frame(width: 26, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).moriPanel(radius: 18)
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private var dailyTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            MoriSectionHeading("日常")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                calendarCard
                backupCard
            }
            downloadsCard
        }
    }
    private var device: some View {
        HomeDeviceCard(isActive: isActive && detail == nil) { open(.monitor) }.id(app.monitorConnectionID)
    }
    private var calendarCard: some View {
        HomeSummaryCard(title: "今日日程", value: Date().formatted(.dateTime.day().locale(Locale(identifier: "zh_Hans_CN"))),
                        subtitle: calendar.layout.lunarDate(on: Date()).description, icon: "calendar", id: "homeCalendar") {
            calendar.today(); open(.calendar)
        }
    }
    private var backupCard: some View {
        HomeSummaryCard(title: "照片备份", value: backup.configuration.enabled ? (backup.running ? "备份中" : "已开启") : "未开启",
                        subtitle: backup.error != nil ? "备份需要检查" : (backup.configuration.enabled ? "已备份 \(backup.ledger.completed.count) 张" : "自动备份新拍照片"),
                        icon: "icloud.and.arrow.up", id: "homeBackup") { openDetail(.backup) }
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
            navigation.storageSection = page == .photos ? "照片" : page == .files ? "文件" : "状态"
            navigation.phoneSelection = .photos
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
        VStack(alignment: .leading, spacing: 14) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive").font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 46, height: 46).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot?.system?.model ?? "群晖 NAS").font(.headline).foregroundStyle(.white)
                        Text(snapshot?.system?.version ?? "设备运行状态").font(.caption).foregroundStyle(NASStyle.heroText)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(NASStyle.heroText)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("homeDevice")
            HStack(spacing: 6) {
                Circle().fill(snapshot?.hasData == true && snapshot?.hasAttention == false && snapshot?.issues.isEmpty == true ? .white : NASStyle.heroText).frame(width: 6, height: 6)
                Text(status).font(.caption).foregroundStyle(NASStyle.heroText).accessibilityIdentifier("homeNASStatus")
                Spacer(minLength: 0)
                Text(snapshot.map { $0.updatedAt.formatted(date: .omitted, time: .shortened) + " 更新" } ?? "等待读取")
                    .font(.caption2).foregroundStyle(NASStyle.heroText).accessibilityIdentifier("homeUpdated")
            }
            HStack(spacing: 0) {
                metric("CPU", value: NASMonitorFormat.percent(snapshot?.resources?.cpu), id: "homeCPU")
                Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 38)
                metric("内存", value: NASMonitorFormat.percent(snapshot?.resources?.memory), id: "homeMemory")
                Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 38)
                metric("温度", value: snapshot?.system?.temperature.map { String(format: "%.0f°", $0) } ?? "—", id: "homeTemperature")
            }.padding(.vertical, 3)
            if let volumes = snapshot?.storage?.volumes, !volumes.isEmpty {
                Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
                ForEach(volumes.prefix(2)) { volume in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).foregroundStyle(NASStyle.heroText)
                            Spacer()
                            Text(NASMonitorFormat.bytes(volume.used) + " / " + NASMonitorFormat.bytes(volume.total))
                                .monospacedDigit().foregroundStyle(NASStyle.heroText)
                        }.font(.caption2)
                        if let fraction = volume.fraction {
                            ProgressView(value: fraction).tint(volume.lowSpace || volume.health == .critical ? .orange : .white)
                        }
                    }
                }
            } else {
                Text(snapshot?.hasData == true ? "存储容量暂不可用" : "连接后查看负载、温度与存储容量")
                    .font(.caption).foregroundStyle(NASStyle.heroText)
            }
        }.padding(20).moriHeroPanel()
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
            Text(title).font(.caption).foregroundStyle(NASStyle.heroText)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white).accessibilityIdentifier(id)
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
                        subtitle: "查看本机下载", icon: "arrow.down.circle", id: "homeDownloads", open: open)
    }
}

private struct HomeSummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let id: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Group {
                if id == "homeDownloads" {
                    HStack(spacing: 10) {
                        Image(systemName: icon).foregroundStyle(NASStyle.accent)
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(value).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: icon).foregroundStyle(NASStyle.accent)
                            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(.primary)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(16).frame(maxWidth: .infinity, minHeight: 116, alignment: .leading).moriPanel()
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}
