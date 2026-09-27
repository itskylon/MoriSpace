import SwiftUI

enum UsageWidgetSize { case small, medium }

struct UsageWidgetContent: View {
    let date: Date
    let snapshot: UsageWidgetSnapshot
    let size: UsageWidgetSize
    var isPreview = false
    @Environment(\.colorScheme) private var colorScheme
    private let signal = Color(red: 0.81, green: 0.98, blue: 0.34)
    private let ink = Color(red: 0.035, green: 0.055, blue: 0.075)
    private let violet = Color(red: 0.85, green: 0.81, blue: 0.98)
    private var visibleWindows: [UsageWidgetWindow] { Array(snapshot.windows.prefix(size == .small ? 1 : 2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? signal : ink)
                Text("Codex 额度").font(.system(size: 12, weight: .bold))
                Spacer(minLength: 2)
                if isPreview {
                    Text("示例").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                } else if snapshot.windows.count > visibleWindows.count {
                    Text("+\(snapshot.windows.count - visibleWindows.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .accessibilityLabel("另有 \(snapshot.windows.count - visibleWindows.count) 个额度窗口，打开 App 查看")
                }
            }
            if snapshot.status != .ready || snapshot.windows.isEmpty {
                emptyContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(visibleWindows.enumerated()), id: \.element.id) { index, window in
                        reading(window, color: index == 0 ? signal : violet)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 4) {
                    if isPreview { Text("仅供样式预览") }
                    else {
                        Text(snapshot.isStale(at: date) ? "上次更新" : "更新于")
                        Text(snapshot.fetchedAt, style: .time)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.status == .notConnected ? "尚未连接" : snapshot.status == .unavailable ? "暂不可用" : "未提供额度")
                .font(.system(size: size == .small ? 24 : 27, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(snapshot.status == .ready ? "当前数据没有可显示的额度窗口" : "打开森空间查看与更新")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isPreview { Text("示例状态").font(.system(size: 9)).foregroundStyle(.secondary) }
        }
    }

    private func reading(_ window: UsageWidgetWindow, color: Color) -> some View {
        let stale = snapshot.requiresRefresh(for: window, at: date)
        let remaining = window.remainingPercent
        return VStack(alignment: .leading, spacing: 2) {
            Text(window.label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            if stale {
                Text("待更新").font(.system(size: 21, weight: .black, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                Text(remaining.map { "上次剩余 " + percentage($0) + "%" } ?? "上次读数未提供")
                    .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
            } else if let remaining {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percentage(remaining)).font(.system(size: 32, weight: .black, design: .rounded)).tracking(-1.5)
                    Text("%").font(.system(size: 16, weight: .bold))
                }.lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityElement(children: .ignore).accessibilityLabel("剩余 \(percentage(remaining)) 百分比")
                HStack(spacing: 5) {
                    Text("剩余").font(.system(size: 8, weight: .medium))
                    GeometryReader { geometry in
                        Capsule().fill(ink.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(ink).frame(width: geometry.size.width * remaining / 100)
                            }
                    }.frame(height: 3).accessibilityHidden(true)
                }
            } else {
                Text("未提供").font(.system(size: 23, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                Text("没有百分比读数").font(.system(size: 9)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let reset = window.resetsAt {
                if reset <= date {
                    Text("重置时间已到，等待新读数").font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text("重置 " + reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                        .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                Text("重置时间未提供").font(.system(size: 8)).lineLimit(1)
            }
        }
        .foregroundStyle(ink).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color, in: RoundedRectangle(cornerRadius: 13))
        .privacySensitive()
    }

    private func percentage(_ value: Double) -> String {
        // Avoid rounding a nearly-full but non-full allowance up to 100%.
        let conservative = floor(value * 10) / 10
        return conservative.formatted(.number.precision(.fractionLength(0...1)))
    }
}

extension UsageWidgetSnapshot {
    /// Synthetic values for WidgetKit's gallery only. Pass isPreview: true when rendering.
    static func sample(now: Date = Date()) -> Self {
        Self(fetchedAt: now, validUntil: now.addingTimeInterval(UsageWidgetConstants.maximumAge), status: .ready, windows: [
            UsageWidgetWindow(id: "sample:primary", label: "Codex · 3 小时", usedPercent: 28, windowMinutes: 180, resetsAt: now.addingTimeInterval(7200)),
            UsageWidgetWindow(id: "sample:secondary", label: "Codex · 2 天", usedPercent: 44, windowMinutes: 2880, resetsAt: now.addingTimeInterval(86400))
        ])
    }
}
