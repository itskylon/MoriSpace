import SwiftUI
import UniformTypeIdentifiers

struct UsageView: View {
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var importingConnection = false
    @State private var showExporter = false
    @State private var exportDocument: UsageRecordDocument?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(at: timeline.date)
                    if let error = usage.error { ErrorBanner(message: error) }
                    if let notice = usage.importNotice {
                        Label(notice, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(NASStyle.accent)
                    }
                    if usage.snapshot.windows.isEmpty { emptyState }
                    else {
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: geometry.size.width >= 660 ? 2 : 1)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(usage.snapshot.windows) { window in windowPanel(window, at: timeline.date) }
                        }
                        recordDetails
                    }
                    sourceDetails
                    previews(width: geometry.size.width, at: timeline.date)
                }.padding(AppPlatform.isMac ? 28 : 20)
                    .frame(maxWidth: 980).frame(maxWidth: .infinity, alignment: .top)
            }.background(NASStyle.canvas)
        }
        }
        .workspaceNavigationTitle("Codex 额度").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        if importingConnection { await usage.connectRemote(from: url) }
                        else { await usage.importSnapshot(from: url) }
                    }
                }
            case .failure:
                usage.reportFileError("未能读取所选文件，请重新选择额度 JSON 记录。")
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "MoriSpace-Codex-Usage") { result in
            if case .failure = result { usage.reportFileError("额度记录未能导出，请重新选择保存位置。") }
        }
        .onDisappear { usage.cancelRefresh() }
        .task(id: "\(scenePhase)-\(usage.syncEnabled)") {
            guard scenePhase == .active else { usage.cancelRefresh(); return }
            usage.reload()
            guard AppPlatform.isMac || usage.syncEnabled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                guard !Task.isCancelled else { break }
                usage.reload()
            }
        }
    }

    private func header(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(NASStyle.ink).frame(width: 48, height: 48)
                    .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("用量，一眼掌握").font(.title3.weight(.bold))
                    Text(statusText(at: date)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("usageStatus")
                }
                Spacer(minLength: 0)
                Button { usage.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("读取最新记录").accessibilityIdentifier("usageRefresh")
                    .help("读取已采集的最新额度记录")
            }
            Text("显示各使用周期的剩余百分比，不是精确的 token 数量。")
                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("usageExplanation")
            if !usage.snapshot.windows.isEmpty, usage.snapshot.isStale(at: date) || usage.snapshot.status != .ready {
                Label("记录需要更新，以下为上次采集的数据。", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium)).foregroundStyle(NASStyle.coral)
            }
        }
    }

    private func statusText(at date: Date) -> String {
        if usage.isFixture { return "预览数据 · 非真实账户额度" }
        if usage.snapshot.windows.isEmpty { return "尚无额度记录" }
        if usage.snapshot.status != .ready { return "采集暂不可用 · 保留上次记录" }
        if usage.snapshot.isStale(at: date) { return "记录已过期" }
        return AppPlatform.isMac ? "本机采集记录" : (usage.syncEnabled ? "外网自动同步已连接" : "导入记录 · 非实时同步")
    }

    private func windowPanel(_ window: UsageWidgetWindow, at date: Date) -> some View {
        let old = usage.snapshot.isStale(at: date) || usage.snapshot.requiresRefresh(for: window, at: date) || usage.snapshot.status != .ready
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(window.label).font(.headline)
                Spacer()
                Text(window.windowMinutes.map(periodDescription) ?? "周期未提供")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.remainingPercent.map { (floor($0 * 10) / 10).formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65).accessibilityIdentifier("usageRemaining")
                Text(old ? "上次剩余" : "剩余").font(.caption).foregroundStyle(.secondary)
            }
            if let used = window.usedPercent {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4).fill(NASStyle.inset)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(used >= 90 ? NASStyle.coral : NASStyle.accent)
                                .frame(width: geometry.size.width * used / 100)
                        }
                }.frame(height: 8).accessibilityHidden(true)
                HStack {
                    Text("已用 " + used.formatted(.number.precision(.fractionLength(0...1))) + "%")
                    Spacer()
                    if old { Text("待更新").foregroundStyle(NASStyle.coral) }
                }.font(.caption).foregroundStyle(.secondary)
            } else { Text("此周期未提供用量数据").font(.caption).foregroundStyle(.secondary) }
            Label(window.resetsAt.map { "重置于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "重置时间未提供", systemImage: "arrow.clockwise")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
    }

    private var recordDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("最后采集", value: usage.snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))
                .accessibilityIdentifier("usageUpdatedAt")
            LabeledContent("记录有效至", value: usage.snapshot.validUntil.formatted(date: .abbreviated, time: .shortened))
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先带入一份额度记录").font(.title2.weight(.bold))
            Text(AppPlatform.isMac
                 ? "请在本机 Codex 完成登录，并启用森空间读取助手。助手生成记录后，这里会自动显示。"
                 : "连接同步服务后，手机和小组件会自动获取 Mac 采集的额度。只需配置一次。")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if AppPlatform.isMac {
                Text("读取助手约每 5 分钟采集一次；此页在前台时每 15 秒从本机助手读取记录。连接仅限这台 Mac，点击刷新不会立即重新采集。")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    do { exportDocument = UsageRecordDocument(data: try usage.exportData()); showExporter = true }
                    catch { usage.reportFileError("当前记录无法导出，请先读取有效的额度记录。") }
                } label: { Label("导出额度记录", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                    .buttonStyle(.plain).foregroundStyle(NASStyle.accent).disabled(usage.snapshot.windows.isEmpty)
                    .accessibilityIdentifier("usageExport")
            } else {
                if usage.syncEnabled {
                    Label("自动同步已连接", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(NASStyle.accent)
                        .accessibilityIdentifier("usageSyncConnected")
                    if let host = usage.syncHost { Text(host).font(.caption).foregroundStyle(.secondary) }
                }
                Text(usage.syncEnabled
                     ? "Mac 约每 5 分钟采集并上传；此页打开时每 15 秒获取一次最新记录。Mac 休眠或离线时保留上次数据。"
                     : "导入一次连接文件，即可通过 HTTPS 在 Wi-Fi 和移动网络下自动同步。连接文件只包含额度服务的只读凭据。")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    if usage.hasPendingRemoteConfiguration {
                        Task { await usage.connectPendingRemote() }
                    } else {
                        importingConnection = true; showImporter = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        if usage.importing { ProgressView() }
                        Label(usage.importing ? "正在验证连接…" : (usage.hasPendingRemoteConfiguration ? "连接已配置的同步服务" : (usage.syncEnabled ? "更换同步连接" : "连接自动同步")), systemImage: "arrow.triangle.2.circlepath")
                    }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                        .foregroundStyle(NASStyle.ink).background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(usage.importing || usage.isFixture).accessibilityIdentifier("usageConnectSync")
                if usage.syncEnabled {
                    Button("停止此设备同步", role: .destructive) { usage.disconnectRemote() }
                        .font(.caption).disabled(usage.importing).accessibilityIdentifier("usageDisconnectSync")
                } else {
                    Button { importingConnection = false; showImporter = true } label: {
                        Label("或导入离线额度记录", systemImage: "square.and.arrow.down")
                    }.font(.caption).disabled(usage.importing || usage.isFixture).accessibilityIdentifier("usageImport")
                }
            }
            Text("小组件显示同一份记录，刷新时机由系统安排。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previews(width: CGFloat, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("小组件预览").font(.title3.weight(.bold))
            let layout = width >= 660 ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            layout {
                UsageWidgetContent(date: date, snapshot: usage.snapshot, size: .small, isPreview: usage.isFixture)
                    .padding(16).frame(width: 170, height: 170)
                    .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("usagePreviewSmall")
                UsageWidgetContent(date: date, snapshot: usage.snapshot, size: .medium, isPreview: usage.isFixture)
                    .padding(16).frame(width: min(348, max(260, width - 40)), height: 170)
                    .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("usagePreviewMedium")
            }
        }.padding(.top, 4)
    }

    private func periodDescription(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天周期" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时周期" }
        return "\(minutes) 分钟周期"
    }
}

private struct UsageRecordDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
