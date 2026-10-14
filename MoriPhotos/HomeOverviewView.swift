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
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if wide {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 20) {
                                storageShortcuts
                                deviceSection
                            }.frame(maxWidth: .infinity)
                            dailyTasks.frame(width: 320)
                        }
                    } else {
                        if typeSize.isAccessibilitySize {
                            deviceSection
                            storageShortcuts
                        } else {
                            storageShortcuts
                            deviceSection
                        }
                        dailyTasks
                    }
                }
                .padding(.horizontal, wide ? 32 : 18).padding(.top, 10).padding(.bottom, 24)
                .frame(maxWidth: 1340).frame(maxWidth: .infinity, alignment: .top)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(AppBrand.name)
                        .font(typeSize.isAccessibilitySize ? .title.weight(.black) : .system(size: 42, weight: .black))
                        .tracking(-1.8).accessibilityIdentifier("homeTitle")
                }
                Spacer(minLength: 0)
                Button { open(.settings) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(NASStyle.ink).frame(width: 48, height: 48)
                        .background(NASStyle.lime, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(MoriPressStyle(scale: 0.945)).accessibilityLabel("设置")
            }
            Rectangle().fill(Color.primary).frame(height: 2)
        }
    }

    private var storageShortcuts: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    photoCover
                    remoteShortcut("群晖照片", subtitle: "个人与共享", icon: "photo.stack", page: .photos, id: "homeNASPhotos", lime: true)
                    remoteShortcut("群晖文件", subtitle: "文件与文档", icon: "folder", page: .files, id: "homeNASFiles", lime: false)
                }
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 10) {
                        photoCover.frame(width: geometry.size.width * 0.57)
                        VStack(spacing: 10) {
                            remoteShortcut("群晖照片", subtitle: "个人与共享", icon: "photo.stack", page: .photos, id: "homeNASPhotos", lime: true)
                            remoteShortcut("群晖文件", subtitle: "文件与文档", icon: "folder", page: .files, id: "homeNASFiles", lime: false)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: usesSidebar ? 260 : 224)
            }
        }
    }

    private var photoCover: some View {
        Button { open(.local) } label: {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        if library.canRead && !library.assets.isEmpty {
                            ForEach(0..<min(3, library.assets.count), id: \.self) { index in
                                AssetImage(asset: library.assets[index])
                                    .id(library.assets[index].localIdentifier)
                                    .frame(width: geometry.size.width * 0.68, height: geometry.size.height * 0.88)
                                    .clipped().overlay(Rectangle().stroke(.white, lineWidth: 3))
                                    .rotationEffect(.degrees(Double(index - 1) * 10))
                                    .offset(x: CGFloat(index - 1) * geometry.size.width * 0.13, y: CGFloat(abs(index - 1)) * 5)
                            }
                        } else {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.white.opacity(0.9))
                                .rotationEffect(.degrees(-9))
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(minHeight: 106).padding(.top, 12).padding(.horizontal, 8)
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机照片").font(typeSize.isAccessibilitySize ? .title2.bold() : .system(size: 25, weight: .bold)).tracking(-0.8)
                        Text(library.canRead ? "\(library.assets.count) 张照片" : "打开照片图库")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NASStyle.ink).frame(width: 32, height: 32).background(NASStyle.lime, in: Circle())
                }.padding(16)
            }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 224)
                .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(MoriPressStyle(scale: 0.945, tilt: -1.6))
            .accessibilityLabel("本机照片，" + (library.canRead ? "\(library.assets.count) 张照片" : "打开照片图库"))
            .accessibilityIdentifier("homeLocalPhotos")
    }

    private func remoteShortcut(_ title: String, subtitle: String, icon: String, page: WorkspacePage, id: String, lime: Bool) -> some View {
        Button { open(page) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 24, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                    Text(subtitle).font(.caption2).opacity(0.65).lineLimit(1)
                }
            }.padding(14).frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
                .foregroundStyle(lime ? NASStyle.ink : Color.primary)
                .background(lime ? NASStyle.lime : NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(MoriPressStyle(scale: 0.945, tilt: lime ? 1.2 : -1.2)).accessibilityIdentifier(id)
    }

    private var dailyTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionRule(title: "日常", number: "02")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                calendarCard
                backupCard
            }
            downloadsCard.padding(.top, 4)
        }
    }
    private var device: some View {
        HomeDeviceCard(isActive: isActive && detail == nil) { open(.monitor) }.id(app.monitorConnectionID)
    }
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionRule(title: "我的设备", number: "01")
            device
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive").font(.system(size: 26)).foregroundStyle(.primary)
                        .frame(width: 46, height: 46).background(NASStyle.selection, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot?.system?.model ?? "群晖 NAS").font(.headline).foregroundStyle(.primary)
                        Text(snapshot?.system?.version ?? "设备运行状态").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(MoriPressStyle(scale: 0.945)).accessibilityIdentifier("homeDevice")
            HStack(spacing: 6) {
                Circle().fill(snapshot?.hasData == true && snapshot?.hasAttention == false && snapshot?.issues.isEmpty == true ? NASStyle.accent : Color.secondary).frame(width: 6, height: 6)
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("homeNASStatus")
                Spacer(minLength: 0)
                Text(snapshot.map { $0.updatedAt.formatted(date: .omitted, time: .shortened) + " 更新" } ?? "等待读取")
                    .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("homeUpdated")
            }
            HStack(spacing: 0) {
                metric("CPU", value: NASMonitorFormat.percent(snapshot?.resources?.cpu), id: "homeCPU")
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 38)
                metric("内存", value: NASMonitorFormat.percent(snapshot?.resources?.memory), id: "homeMemory")
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 38)
                metric("温度", value: snapshot?.system?.temperature.map { String(format: "%.0f°", $0) } ?? "—", id: "homeTemperature")
            }.padding(.vertical, 3)
            if let volumes = snapshot?.storage?.volumes, !volumes.isEmpty {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
                ForEach(volumes.prefix(2)) { volume in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).foregroundStyle(.secondary)
                            Spacer()
                            Text(NASMonitorFormat.bytes(volume.used) + " / " + NASMonitorFormat.bytes(volume.total))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption2)
                        if let fraction = volume.fraction {
                            GeometryReader { geometry in
                                Capsule().fill(Color.white.opacity(0.13))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(volume.lowSpace || volume.health == .critical ? Color.orange : NASStyle.lime)
                                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                                    }
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                    }
                }
            } else {
                Text(snapshot?.hasData == true ? "存储容量暂不可用" : "连接后查看负载、温度与存储容量")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(NASStyle.ink, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .task(id: "\(isActive)-\(scenePhase)") {
            guard isActive && scenePhase == .active else { store.stop(); return }
            await app.restoreConnection(service: .monitor)
            guard !Task.isCancelled, let client = app.monitorClient else { return }
            store.start(client: client, automatic: true)
        }
        .onDisappear { store.stop() }
    }
    private func metric(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).tracking(-1).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(NASStyle.lime).accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Button(action: open) {
            if id == "homeDownloads" {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.title3).foregroundStyle(NASStyle.accent)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(value).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 50).contentShape(Rectangle())
                    .overlay(alignment: .top) { Rectangle().fill(NASStyle.outline).frame(height: 1) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(title).font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                    }.foregroundStyle(.secondary)
                    Text(value).font(typeSize.isAccessibilitySize ? .title.bold() : .system(size: id == "homeCalendar" ? 46 : 26, weight: .bold))
                        .tracking(-1.6).foregroundStyle(.primary).minimumScaleFactor(0.8)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }.padding(.vertical, 12).padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(id == "homeCalendar" ? NASStyle.accent : Color.primary).frame(height: 3) }
                    .contentShape(Rectangle())
            }
        }.buttonStyle(MoriPressStyle(scale: 0.945)).accessibilityIdentifier(id)
    }
}

private struct HomeSectionRule: View {
    let title: String
    let number: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.bold)).accessibilityAddTraits(.isHeader)
            Rectangle().fill(NASStyle.outline).frame(height: 1)
            Text(number).font(.caption2.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}
