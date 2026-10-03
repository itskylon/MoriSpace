import SwiftUI
import Charts

/// The desktop layout uses explicit columns so unused adaptive-grid slots cannot leave gaps.
struct NASMonitorDesktopDashboard: View {
    let snapshot: NASMonitorSnapshot
    let samples: [NASLoadSample]
    let width: CGFloat
    private let memoryColor = NASStyle.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let resources = snapshot.resources {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: width >= 820 ? 4 : 2), spacing: 12) {
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
            if width >= 820, snapshot.resources != nil, let storage = snapshot.storage {
                HStack(alignment: .top, spacing: 16) {
                    trend.frame(maxWidth: .infinity)
                    volumes(storage).frame(width: min(420, (width - 16) * 0.42))
                }
            } else {
                if snapshot.resources != nil { trend }
                if let storage = snapshot.storage { volumes(storage) }
            }
            if let storage = snapshot.storage { disks(storage) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, symbol: String, value: String, detail: String, percentage: Double?, color: Color, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).foregroundStyle(color)
            }.foregroundStyle(.secondary)
            Text(value).font(.system(size: width >= 1000 ? 36 : 30, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55).accessibilityIdentifier(identifier)
            VStack(alignment: .leading, spacing: 10) {
                if let percentage { MonitorUsageBar(fraction: percentage / 100, color: color, track: NASStyle.inset) }
                else { Color.clear.frame(height: 6).accessibilityHidden(true) }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(NASStyle.outline, lineWidth: 0.5) }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("负载趋势").font(.headline)
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
                            AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%").font(.caption2) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path").foregroundStyle(NASStyle.accent)
                        Text("下次刷新后显示趋势").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: samples.count >= 2 ? 166 : 44)
            Text("本次查看的 CPU 与内存使用率").font(.caption).foregroundStyle(.secondary)
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
                        Text(volume.id.replacingOccurrences(of: "volume_", with: "存储空间 ")).font(.subheadline.weight(.medium))
                        Spacer()
                        health(volume.health, raw: volume.rawStatus)
                    }
                    if let fraction = volume.fraction {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(NASMonitorFormat.bytes(volume.used)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            Text("/ " + NASMonitorFormat.bytes(volume.total)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(NASMonitorFormat.percent(fraction * 100)).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        MonitorUsageBar(fraction: fraction, color: volume.lowSpace ? NASStyle.coral : NASStyle.accent, height: 8)
                    } else { Text("容量信息不可用").font(.caption).foregroundStyle(.secondary) }
                    if volume.lowSpace { Label("已用空间达到 90%，建议清理", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.accessibilityIdentifier("monitorVolume_" + volume.id)
                if volume.id != items.last?.id { Rectangle().fill(NASStyle.outline).frame(height: 1).padding(.vertical, 4) }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).desktopMonitorPanel()
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
                }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(storage.disks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { disk in
                    Rectangle().fill(NASStyle.outline).frame(height: 1)
                    HStack(spacing: 8) {
                        Label(disk.name, systemImage: "internaldrive")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                        health(disk.health, raw: disk.rawStatus).frame(width: 180, alignment: .leading)
                        Text(disk.temperature.map { String(format: "%.0f°C", $0) } ?? "—")
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }.padding(.vertical, 12).accessibilityIdentifier("monitorDisk_" + disk.id)
                }
            }
        }.desktopMonitorPanel()
    }

    private func panelTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(String(count)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func health(_ value: NASHealth, raw: String?) -> some View {
        Label(value.title + (value == .normal || raw == nil ? "" : " · " + raw!), systemImage: value == .normal ? "checkmark.circle" : "exclamationmark.circle")
            .font(.caption.weight(.medium)).foregroundStyle(value == .normal ? NASStyle.accent : (value == .unknown ? .secondary : Color.orange))
    }
    private func rate(_ value: Double?) -> String { value.map { NASMonitorFormat.bytes($0) + "/s" } ?? "—" }
}

private struct MonitorUsageBar: View {
    let fraction: Double
    let color: Color
    var track: Color = Color.primary.opacity(0.07)
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3).fill(track)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
        }.frame(height: height).accessibilityHidden(true)
    }
}

private extension View {
    func desktopMonitorPanel() -> some View {
        padding(18).background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(NASStyle.outline, lineWidth: 0.5) }
    }
}
