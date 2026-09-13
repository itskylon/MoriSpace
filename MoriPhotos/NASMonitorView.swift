import SwiftUI
import Charts

struct NASMonitorHomeView: View {
    var isActive = true
    @EnvironmentObject private var app: AppState
    @State private var connection = false
    var body: some View {
        Group {
            if let client = app.monitorClient {
                NASMonitorView(client: client, isActive: isActive).id(app.monitorConnectionID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        NASConnectionStatus(service: .monitor)
                        Button { connection = true } label: {
                            NASActionLabel(title: app.hasSavedConnection ? "状态连接设置" : "连接 NAS 状态", subtitle: "CPU、内存与存储", symbol: "waveform.path.ecg")
                        }.buttonStyle(.plain).accessibilityIdentifier("connectMonitor")
                        Text("使用已保存账号读取运行状态。部分 DSM 系统监控项目需要管理员权限。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(16)
                }.background(NASStyle.canvas)
            }
        }.workspaceNavigationTitle("NAS 状态").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .monitor) } }
            .task(id: isActive) { if isActive { await app.restoreConnection(service: .monitor) } }
    }
}

struct NASMonitorView: View {
    let client: SynologyClient
    var isActive = true
    @StateObject private var store = NASMonitorStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var automatic = true
    @State private var connection = false
    private var snapshot: NASMonitorSnapshot? { store.snapshot }
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if AppPlatform.isMac { desktopHeader.padding(.bottom, 6) }
                else { statusHeader }
                if store.loading && snapshot == nil { ProgressView("正在读取运行状态…").frame(maxWidth: .infinity).padding(24) }
                if let snapshot {
                    ForEach(snapshot.issues) { issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(issue.section + "暂不可用", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
                            Text(issue.message).font(.caption)
                        }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("monitorIssue_" + issue.section)
                    }
                    if snapshot.hasData {
                        if AppPlatform.isMac {
                            NASMonitorDesktopDashboard(snapshot: snapshot, samples: store.samples, width: geometry.size.width - 48)
                        } else {
                            if let system = snapshot.system { systemSummary(system) }
                            if let resources = snapshot.resources { resourceCards(resources) }
                            if let storage = snapshot.storage { storageSection(storage) }
                        }
                    }
                }
                Text(AppPlatform.isMac ? "仅在此页面打开且 App 位于前台时更新" : "仅在此页打开且 App 位于前台时刷新。锁屏或离开后暂停；不提供后台告警推送。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(AppPlatform.isMac ? 24 : 16)
        }.background(NASStyle.canvas)
            .refreshable { await store.refresh(client: client) }
        }
            .toolbar {
                if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("立即刷新", systemImage: "arrow.clockwise") { Task { await store.refresh(client: client) } }.disabled(store.loading)
                        Toggle("每 15 秒自动刷新", isOn: $automatic)
                        Button("状态连接设置", systemImage: "slider.horizontal.3") { connection = true }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.primary) }
                        .accessibilityLabel("状态选项").accessibilityIdentifier("monitorOptions")
                }
                }
            }
            .sheet(isPresented: $connection) { NavigationStack { ConnectionView(service: .monitor) } }
            .onAppear { visible = true; updatePolling() }
            .onDisappear { visible = false; store.stop() }
            .onChange(of: scenePhase) { _, _ in updatePolling() }
            .onChange(of: automatic) { _, _ in updatePolling() }
            .onChange(of: isActive) { _, _ in updatePolling() }
    }

    private func updatePolling() {
        if isActive && visible && scenePhase == .active { store.start(client: client, automatic: automatic) }
        else { store.stop() }
    }

    private var desktopHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Text(snapshot?.system?.model ?? "Synology NAS").font(.system(size: 24, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusTitle).font(.caption).foregroundStyle(statusColor).accessibilityIdentifier("monitorStatus")
                    }
                }
                if let system = snapshot?.system {
                    HStack(spacing: 10) {
                        Text(system.version ?? "系统版本未提供")
                        Text("·")
                        Text("运行 " + NASMonitorFormat.uptime(system.uptime))
                        if let temperature = system.temperature {
                            Label(String(format: "%.0f°C", temperature), systemImage: "thermometer.medium")
                                .foregroundStyle(system.temperatureWarning == true ? Color.orange : .secondary)
                                .help(system.temperatureWarning == true ? "系统温度告警" : "系统温度")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button { automatic.toggle() } label: {
                        Label(automatic && !store.halted ? "每 15 秒刷新" : "手动刷新", systemImage: automatic && !store.halted ? "arrow.triangle.2.circlepath" : "pause.circle")
                            .font(.caption.weight(.medium)).padding(.horizontal, 10).frame(height: 30)
                            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("monitorAutoRefresh")
                    Button { Task { await store.refresh(client: client) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
                            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(store.loading).accessibilityLabel("刷新运行状态").accessibilityIdentifier("refreshMonitor")
                }
                Text(snapshot.map { "更新于 " + $0.updatedAt.formatted(date: .omitted, time: .standard) } ?? "等待读取")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityIdentifier("monitorUpdated")
            }.fixedSize()
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("monitorStatus")
                }
                Text(snapshot.map { "更新于 " + $0.updatedAt.formatted(date: .omitted, time: .standard) } ?? "等待读取")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("monitorUpdated")
            }
            Spacer()
            Button { automatic.toggle() } label: {
                Label(automatic && !store.halted ? "15 秒刷新" : "手动刷新", systemImage: automatic && !store.halted ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 8)
                    .foregroundStyle(NASStyle.accent).background(NASStyle.accent.opacity(0.08), in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("monitorAutoRefresh")
            Button { Task { await store.refresh(client: client) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 40, height: 44)
            }.buttonStyle(.plain).foregroundStyle(Color.primary).disabled(store.loading)
                .accessibilityLabel("刷新运行状态").accessibilityIdentifier("refreshMonitor")
        }
    }
    private var statusTitle: String {
        guard let snapshot else { return "连接中" }
        if !snapshot.hasData { return "暂时无法读取" }
        if !snapshot.issues.isEmpty { return "部分数据不可用" }
        if snapshot.hasAttention { return "有项目需关注" }
        return "已连接"
    }
    private var statusColor: Color {
        guard let snapshot else { return .secondary }
        return !snapshot.hasData || !snapshot.issues.isEmpty || snapshot.hasAttention ? .orange : NASStyle.accent
    }
    private func systemSummary(_ system: NASSystemStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill").font(.system(size: 25)).foregroundStyle(NASStyle.accent)
                .frame(width: 46, height: 46).background(NASStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(system.model ?? "Synology NAS").font(.headline)
                Text(system.version ?? "系统版本未提供").font(.caption).foregroundStyle(.secondary)
                Text("已运行 " + NASMonitorFormat.uptime(system.uptime)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(system.temperature.map { String(format: "%.0f°", $0) } ?? "—").font(.title2.weight(.medium)).monospacedDigit()
                Text(system.temperatureWarning == true ? "温度告警" : "系统温度").font(.caption2)
            }.foregroundStyle(system.temperatureWarning == true ? Color.orange : .secondary)
        }.monitorCard()
    }
    private func resourceCards(_ resources: NASResourceStatus) -> some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                percentageCard("CPU", value: resources.cpu, symbol: "cpu", subtitle: "当前负载", identifier: "monitorCPU")
                percentageCard("内存", value: resources.memory, symbol: "memorychip", subtitle: "共 " + NASMonitorFormat.bytes(resources.memoryBytes), identifier: "monitorMemory")
            }
            HStack(spacing: 12) {
                networkRate("接收", symbol: "arrow.down", value: resources.receivedBytesPerSecond)
                Divider()
                networkRate("发送", symbol: "arrow.up", value: resources.sentBytesPerSecond)
            }.fixedSize(horizontal: false, vertical: true).monitorCard()
            if store.samples.count >= 2 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("负载趋势").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("本次查看 · 最多 40 次").font(.caption2).foregroundStyle(.secondary)
                    }
                    Chart(store.samples) { sample in
                        if let cpu = sample.cpu {
                            LineMark(x: .value("时间", sample.date), y: .value("使用率", cpu))
                                .foregroundStyle(by: .value("指标", "CPU"))
                        }
                        if let memory = sample.memory {
                            LineMark(x: .value("时间", sample.date), y: .value("使用率", memory))
                                .foregroundStyle(by: .value("指标", "内存"))
                        }
                    }.chartYScale(domain: 0...100).chartForegroundStyleScale(["CPU": NASStyle.accent, "内存": Color.blue])
                        .chartXAxis(.hidden).frame(height: 86)
                }.monitorCard().accessibilityIdentifier("monitorTrend")
            }
        }
    }
    private func percentageCard(_ title: String, value: Double?, symbol: String, subtitle: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(NASMonitorFormat.percent(value)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                .accessibilityIdentifier(identifier)
            ProgressView(value: value ?? 0, total: 100).tint(NASStyle.accent).opacity(value == nil ? 0 : 1).accessibilityHidden(true)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).monitorCard()
    }
    private func networkRate(_ title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("NAS " + title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value == nil ? "—" : NASMonitorFormat.bytes(value) + "/s").font(.subheadline.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func storageSection(_ storage: NASStorageStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("存储空间").font(.subheadline.weight(.semibold)).padding(.top, 4)
            if storage.volumes.isEmpty {
                Text(storage.volumesReported ? "未返回存储空间" : "NAS 未提供存储空间数据").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(storage.volumes) { volume in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).font(.subheadline.weight(.semibold))
                        Spacer()
                        healthLabel(volume.health, raw: volume.rawStatus)
                    }
                    if let fraction = volume.fraction {
                        ProgressView(value: fraction).tint(volume.lowSpace ? .orange : NASStyle.accent)
                        Text(NASMonitorFormat.bytes(volume.used) + " / " + NASMonitorFormat.bytes(volume.total) + " · " + NASMonitorFormat.percent(fraction * 100))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("容量信息不可用").font(.caption).foregroundStyle(.secondary) }
                    if volume.lowSpace { Label("已用空间达到 90%，建议清理", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.monitorCard().accessibilityIdentifier("monitorVolume_" + volume.id)
            }
            Text("硬盘健康").font(.subheadline.weight(.semibold)).padding(.top, 4)
            if storage.disks.isEmpty {
                Text(storage.disksReported ? "未返回硬盘信息" : "NAS 未提供硬盘数据").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(storage.disks) { disk in
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive").foregroundStyle(NASStyle.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(disk.name).font(.subheadline.weight(.medium))
                        healthLabel(disk.health, raw: disk.rawStatus)
                    }
                    Spacer()
                    Text(disk.temperature.map { String(format: "%.0f°C", $0) } ?? "—").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }.monitorCard().accessibilityIdentifier("monitorDisk_" + disk.id)
            }
        }
    }
    private func healthLabel(_ health: NASHealth, raw: String?) -> some View {
        Label(health.title + (health == .normal || raw == nil ? "" : " · " + raw!), systemImage: health == .normal ? "checkmark.circle" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(health == .normal ? NASStyle.accent : (health == .unknown ? .secondary : Color.orange))
    }
}

private extension View {
    func monitorCard() -> some View {
        padding(14).background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
    }
}
