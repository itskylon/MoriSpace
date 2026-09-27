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
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .top)
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
            VStack(alignment: .leading, spacing: 18) {
                if geometry.size.width >= 700 { desktopHeader.padding(.bottom, 4) }
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
                        if geometry.size.width >= 700 {
                            NASMonitorDesktopDashboard(snapshot: snapshot, samples: store.samples, width: geometry.size.width - 48)
                        } else {
                            if let resources = snapshot.resources { resourceCards(resources) }
                            if let storage = snapshot.storage { storageSection(storage) }
                            if snapshot.resources != nil { mobileTrend }
                        }
                    }
                }
                Label(AppPlatform.isMac ? "仅在当前页面且 App 位于前台时更新" : "离开此页或锁屏后暂停更新，不提供后台告警。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(geometry.size.width >= 700 ? 24 : 16)
            .frame(maxWidth: .infinity, alignment: .top)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                deviceIdentity
                Spacer(minLength: 12)
                desktopRefreshControls
            }
            VStack(alignment: .leading, spacing: 16) {
                deviceIdentity
                desktopRefreshControls
            }
        }
    }

    private var deviceIdentity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(snapshot?.system?.model ?? "Synology NAS").font(.system(size: 32, weight: .bold, design: .rounded))
                connectionStatus
            }
            if let system = snapshot?.system {
                HStack(spacing: 12) {
                    Text(system.version ?? "系统版本未提供")
                    Text("运行 " + NASMonitorFormat.uptime(system.uptime))
                    if let temperature = system.temperature {
                        Label(String(format: "%.0f°C", temperature), systemImage: "thermometer.medium")
                            .foregroundStyle(system.temperatureWarning == true ? Color.orange : .secondary)
                            .help(system.temperatureWarning == true ? "系统温度告警" : "系统温度")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(statusTitle).font(.caption).foregroundStyle(statusColor).accessibilityIdentifier("monitorStatus")
        }
    }

    private var desktopRefreshControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Button { automatic.toggle() } label: {
                    Label(automatic && !store.halted ? "每 15 秒刷新" : "手动刷新", systemImage: automatic && !store.halted ? "arrow.triangle.2.circlepath" : "pause.circle")
                        .font(.caption.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("monitorAutoRefresh")
                Button { Task { await store.refresh(client: client) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.loading).accessibilityLabel("刷新运行状态").accessibilityIdentifier("refreshMonitor")
            }
            Text(snapshot.map { "更新于 " + $0.updatedAt.formatted(date: .omitted, time: .standard) } ?? "等待读取")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("monitorUpdated")
        }.fixedSize()
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot?.system?.model ?? "Synology NAS").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    if let system = snapshot?.system {
                        if let version = system.version {
                            Text(version).font(.caption2).foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Text("已运行 " + NASMonitorFormat.uptime(system.uptime))
                            .font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { automatic.toggle() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: automatic && !store.halted ? "arrow.triangle.2.circlepath" : "pause.circle")
                        Text(automatic && !store.halted ? "15 秒" : "手动").font(.caption2)
                    }.foregroundStyle(NASStyle.signal).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(automatic && !store.halted ? "每 15 秒刷新" : "手动刷新").accessibilityIdentifier("monitorAutoRefresh")
                Button { Task { await store.refresh(client: client) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white).disabled(store.loading)
                    .accessibilityLabel("刷新运行状态").accessibilityIdentifier("refreshMonitor")
            }
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(snapshot?.hasAttention == true || snapshot?.hasData == false || snapshot?.issues.isEmpty == false ? NASStyle.coral : NASStyle.signal).frame(width: 5, height: 5)
                    Text(statusTitle).font(.caption).foregroundStyle(.white).accessibilityIdentifier("monitorStatus")
                }
                if let system = snapshot?.system, let temperature = system.temperature {
                    Text(String(format: "%.0f°C", temperature)).font(.caption).monospacedDigit()
                        .foregroundStyle(system.temperatureWarning == true ? Color.orange : .white.opacity(0.62))
                        .accessibilityLabel(system.temperatureWarning == true ? "系统温度告警，\(String(format: "%.0f", temperature)) 摄氏度" : "系统温度，\(String(format: "%.0f", temperature)) 摄氏度")
                }
                Spacer(minLength: 0)
                Text(snapshot.map { $0.updatedAt.formatted(date: .omitted, time: .standard) + " 更新" } ?? "等待读取")
                    .font(.caption2).foregroundStyle(.white.opacity(0.62)).accessibilityIdentifier("monitorUpdated")
            }
        }.padding(14).background(NASStyle.ink, in: RoundedRectangle(cornerRadius: 22))
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
    private func resourceCards(_ resources: NASResourceStatus) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                percentageCard("CPU", value: resources.cpu, symbol: "cpu", subtitle: "当前负载", identifier: "monitorCPU")
                percentageCard("内存", value: resources.memory, symbol: "memorychip", subtitle: NASMonitorFormat.bytes(resources.memoryBytes), identifier: "monitorMemory")
            }
            HStack(spacing: 20) {
                networkRate("接收", symbol: "arrow.down.left", value: resources.receivedBytesPerSecond)
                networkRate("发送", symbol: "arrow.up.right", value: resources.sentBytesPerSecond)
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var mobileTrend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("负载趋势").font(.title3.weight(.bold))
                Spacer()
                Text("本次查看").font(.caption).foregroundStyle(.secondary)
            }
            if store.samples.count >= 2 {
                Chart(store.samples) { sample in
                    if let cpu = sample.cpu {
                        LineMark(x: .value("时间", sample.date), y: .value("使用率", cpu))
                            .foregroundStyle(by: .value("指标", "CPU")).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if let memory = sample.memory {
                        LineMark(x: .value("时间", sample.date), y: .value("使用率", memory))
                            .foregroundStyle(by: .value("指标", "内存")).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                .chartYScale(domain: 0...100).chartForegroundStyleScale(["CPU": NASStyle.accent, "内存": NASStyle.violet])
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(NASStyle.outline)
                        AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%").font(.caption2) } }
                    }
                }
                .frame(height: 96)
            } else {
                Text("下次刷新后显示趋势").font(.caption).foregroundStyle(.secondary)
            }
        }.monitorSection().accessibilityIdentifier("monitorTrend")
    }

    private func percentageCard(_ title: String, value: Double?, symbol: String, subtitle: String, identifier: String) -> some View {
        let isCPU = title == "CPU"
        let foreground = isCPU ? NASStyle.ink : Color.primary
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(title, systemImage: symbol).font(.caption.weight(.bold))
                Spacer(minLength: 0)
            }.foregroundStyle(foreground.opacity(0.7))
            HStack(alignment: .firstTextBaseline) {
                Text(NASMonitorFormat.percent(value)).font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier(identifier)
                Spacer(minLength: 0)
            }
            Text(subtitle).font(.caption2).foregroundStyle(foreground.opacity(0.65))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2).fill(foreground.opacity(0.1))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(isCPU ? NASStyle.ink : NASStyle.violet)
                            .frame(width: geometry.size.width * min(max((value ?? 0) / 100, 0), 1))
                    }
            }.frame(height: 5).opacity(value == nil ? 0 : 1).accessibilityHidden(true)
        }.foregroundStyle(foreground).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(isCPU ? NASStyle.signal : NASStyle.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
    }

    private func networkRate(_ title: String, symbol: String, value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(title == "接收" ? NASStyle.blue : NASStyle.coral).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(value == nil ? "—" : NASMonitorFormat.bytes(value) + "/s").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .accessibilityIdentifier(title == "接收" ? "monitorReceive" : "monitorSend")
                Text("NAS " + title).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func storageSection(_ storage: NASStorageStatus) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("存储空间").font(.title3.weight(.bold))
                if storage.volumes.isEmpty {
                    Text(storage.volumesReported ? "未返回存储空间" : "NAS 未提供存储空间数据").font(.caption).foregroundStyle(.secondary)
                }
                let volumes = storage.volumes.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                ForEach(volumes) { volume in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).font(.subheadline.weight(.medium))
                            Spacer()
                            healthLabel(volume.health, raw: volume.rawStatus)
                        }
                        if let fraction = volume.fraction {
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 3).fill(NASStyle.inset)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3).fill(volume.lowSpace ? NASStyle.coral : NASStyle.accent)
                                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                                    }
                            }.frame(height: 12).accessibilityHidden(true)
                            HStack {
                                Text(NASMonitorFormat.bytes(volume.used) + " / " + NASMonitorFormat.bytes(volume.total))
                                Spacer()
                                Text(NASMonitorFormat.percent(fraction * 100)).monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                        } else { Text("容量信息不可用").font(.caption).foregroundStyle(.secondary) }
                        if volume.lowSpace { Label("已用空间达到 90%，建议清理", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }.accessibilityIdentifier("monitorVolume_" + volume.id)

                }
            }.monitorSection()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("硬盘健康").font(.title3.weight(.bold))
                    Spacer()
                    Text("\(storage.disks.count) 块").font(.caption).foregroundStyle(.secondary)
                }
                if storage.disks.isEmpty {
                    Text(storage.disksReported ? "未返回硬盘信息" : "NAS 未提供硬盘数据").font(.caption).foregroundStyle(.secondary)
                }
                let disks = storage.disks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                ForEach(disks) { disk in
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive").foregroundStyle(NASStyle.accent).frame(width: 26)
                        Text(disk.name).font(.subheadline.weight(.medium))
                        Spacer(minLength: 4)
                        healthLabel(disk.health, raw: disk.rawStatus)
                        Text(disk.temperature.map { String(format: "%.0f°C", $0) } ?? "—")
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }.frame(minHeight: 36).accessibilityIdentifier("monitorDisk_" + disk.id)
                    if disk.id != disks.last?.id { Divider() }
                }
            }.monitorSection()
        }
    }
    private func healthLabel(_ health: NASHealth, raw: String?) -> some View {
        Label(health.title + (health == .normal || raw == nil ? "" : " · " + raw!), systemImage: health == .normal ? "checkmark.circle" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(health == .normal ? NASStyle.accent : (health == .unknown ? .secondary : Color.orange))
    }
}

private extension View {
    func monitorSection() -> some View {
        padding(.top, 16).overlay(alignment: .top) { Rectangle().fill(NASStyle.outline).frame(height: 1) }
    }
}
