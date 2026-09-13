import SwiftUI
import Charts

/// The desktop layout uses explicit columns so unused adaptive-grid slots cannot leave gaps.
struct NASMonitorDesktopDashboard: View {
    let snapshot: NASMonitorSnapshot
    let samples: [NASLoadSample]
    let width: CGFloat
    private let memoryColor = Color(red: 0.61, green: 0.65, blue: 0.89)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let resources = snapshot.resources {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: width >= 780 ? 4 : 2), spacing: 12) {
                    metric("CPU", symbol: "cpu", value: NASMonitorFormat.percent(resources.cpu),
                           detail: "处理器负载", percentage: resources.cpu, color: NASStyle.accent, identifier: "monitorCPU")
                    metric("内存", symbol: "memorychip", value: NASMonitorFormat.percent(resources.memory),
                           detail: "共 " + NASMonitorFormat.bytes(resources.memoryBytes), percentage: resources.memory, color: memoryColor, identifier: "monitorMemory")
                    metric("接收", symbol: "arrow.down.left", value: rate(resources.receivedBytesPerSecond),
                           detail: "NAS 实时接收", percentage: nil, color: NASStyle.accent, identifier: "monitorReceive")
                    metric("发送", symbol: "arrow.up.right", value: rate(resources.sentBytesPerSecond),
                           detail: "NAS 实时发送", percentage: nil, color: NASStyle.accent, identifier: "monitorSend")
                }
            }
            if width >= 780, snapshot.resources != nil, let storage = snapshot.storage {
                HStack(alignment: .top, spacing: 16) {
                    trend.frame(maxWidth: .infinity)
                    volumes(storage).frame(maxWidth: .infinity)
                }
            } else {
                if snapshot.resources != nil { trend }
                if let storage = snapshot.storage { volumes(storage) }
            }
            if let storage = snapshot.storage { disks(storage) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, symbol: String, value: String, detail: String, percentage: Double?, color: Color, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color)
            }
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75).accessibilityIdentifier(identifier)
            HStack(spacing: 12) {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                if let percentage { MonitorUsageBar(fraction: percentage / 100, color: color).frame(maxWidth: 80) }
                else { Spacer(minLength: 0) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).desktopMonitorPanel()
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("负载趋势").font(.system(size: 13, weight: .semibold))
                Spacer()
                legend("CPU", color: NASStyle.accent)
                legend("内存", color: memoryColor)
            }
            Group {
                if samples.count >= 2 {
                    Chart(samples) { sample in
                        if let cpu = sample.cpu {
                            LineMark(x: .value("时间", sample.date), y: .value("使用率", cpu))
                                .foregroundStyle(by: .value("指标", "CPU"))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                        if let memory = sample.memory {
                            LineMark(x: .value("时间", sample.date), y: .value("使用率", memory))
                                .foregroundStyle(by: .value("指标", "内存"))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartForegroundStyleScale(["CPU": NASStyle.accent, "内存": memoryColor])
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%").font(.system(size: 9)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.path").font(.system(size: 26, weight: .light)).foregroundStyle(NASStyle.accent.opacity(0.65))
                        Text("正在积累采样数据").font(.caption).foregroundStyle(.secondary)
                        Text("再次刷新后显示趋势").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 164)
            Text("本次查看的 CPU 与内存使用率").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.desktopMonitorPanel().accessibilityIdentifier("monitorTrend")
    }

    private func volumes(_ storage: NASStorageStatus) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("存储空间", count: storage.volumes.count)
            if storage.volumes.isEmpty {
                Text(storage.volumesReported ? "未返回存储空间" : "NAS 未提供存储空间数据").font(.caption).foregroundStyle(.secondary)
            }
            let items = storage.volumes.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            ForEach(items) { volume in
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        health(volume.health, raw: volume.rawStatus)
                    }
                    if let fraction = volume.fraction {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(NASMonitorFormat.bytes(volume.used)).font(.system(size: 19, weight: .medium)).monospacedDigit()
                            Text("/ " + NASMonitorFormat.bytes(volume.total)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(NASMonitorFormat.percent(fraction * 100)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        MonitorUsageBar(fraction: fraction, color: volume.lowSpace ? .orange : NASStyle.accent)
                    } else { Text("容量信息不可用").font(.caption).foregroundStyle(.secondary) }
                    if volume.lowSpace { Label("已用空间达到 90%，建议清理", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.accessibilityIdentifier("monitorVolume_" + volume.id)
                if volume.id != items.last?.id { Divider().overlay(NASStyle.outline) }
            }
        }.frame(maxWidth: .infinity, minHeight: width >= 780 && snapshot.resources != nil ? 228 : nil, alignment: .topLeading).desktopMonitorPanel()
    }

    private func disks(_ storage: NASStorageStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTitle("硬盘健康", count: storage.disks.count).padding(.bottom, 18)
            if storage.disks.isEmpty {
                Text(storage.disksReported ? "未返回硬盘信息" : "NAS 未提供硬盘数据").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("硬盘").frame(maxWidth: .infinity, alignment: .leading)
                    Text("状态").frame(width: 180, alignment: .leading)
                    Text("温度").frame(width: 70, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 8)
                ForEach(storage.disks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { disk in
                    Divider().overlay(NASStyle.outline)
                    HStack(spacing: 8) {
                        Label(disk.name, systemImage: "internaldrive")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        health(disk.health, raw: disk.rawStatus).frame(width: 180, alignment: .leading)
                        Text(disk.temperature.map { String(format: "%.0f°C", $0) } ?? "—")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }.padding(.vertical, 14).accessibilityIdentifier("monitorDisk_" + disk.id)
                }
            }
        }.desktopMonitorPanel()
    }

    private func panelTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(count) 项").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
    private func health(_ value: NASHealth, raw: String?) -> some View {
        Label(value.title + (value == .normal || raw == nil ? "" : " · " + raw!), systemImage: value == .normal ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(value == .normal ? NASStyle.accent : (value == .unknown ? .secondary : Color.orange))
    }
    private func rate(_ value: Double?) -> String { value.map { NASMonitorFormat.bytes($0) + "/s" } ?? "—" }
}

private struct MonitorUsageBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

private extension View {
    func desktopMonitorPanel() -> some View {
        padding(18).background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
    }
}
