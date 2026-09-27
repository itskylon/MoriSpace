import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var backup: PhotoBackupManager
    @EnvironmentObject private var oneDrive: OneDriveSession
    @State private var cleared = false
    @State private var showDetails = false

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image("AppBrand").resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("森空间").font(.headline)
                        Text("版本 \(version) · 个人使用版").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("appVersion")
                    }
                    Spacer()
                }.padding(.horizontal, 4)

                preferencesSection("存储服务") {
                    NavigationLink { ConnectionView() } label: {
                        SettingsRow(title: "群晖照片", subtitle: "Synology Photos", symbol: "photo.on.rectangle", value: app.client == nil ? "未连接" : "已连接")
                    }
                    rowDivider
                    NavigationLink { ConnectionView(service: .files) } label: {
                        SettingsRow(title: "群晖文件", subtitle: "File Station", symbol: "folder", value: app.fileClient == nil ? "未连接" : "已连接")
                    }
                    rowDivider
                    NavigationLink { OneDriveConnectionView() } label: {
                        SettingsRow(title: "OneDrive", subtitle: "微软云存储", symbol: "cloud", value: oneDrive.account == nil ? "未连接" : "已连接")
                    }.accessibilityIdentifier("oneDriveSettings")
                }

                preferencesSection("备份与设备") {
                    NavigationLink { PhotoBackupView() } label: {
                        SettingsRow(title: "新照片备份", subtitle: "原图保存到群晖", symbol: "arrow.up.doc", value: backup.configuration.enabled ? "已开启" : "未开启")
                    }.accessibilityIdentifier("newPhotoBackupSettings")
                    rowDivider
                    NavigationLink { NASMonitorHomeView() } label: {
                        SettingsRow(title: "NAS 运行状态", subtitle: "负载、容量与硬盘健康", symbol: "waveform.path.ecg")
                    }
                }

                preferencesSection("本机设置") {
                    Button { AppPlatform.openPhotoSettings() } label: {
                        SettingsRow(title: "照片权限", subtitle: AppPlatform.libraryName, symbol: "hand.raised", value: library.canRead ? (library.authorization == .limited ? "部分照片" : "全部照片") : "未授权")
                    }.accessibilityLabel("打开系统权限设置")
                    rowDivider
                    Button {
                        library.manager.stopCachingImagesForAllAssets()
                        Task { await app.client?.clearCache(); cleared = true }
                    } label: {
                        SettingsRow(title: cleared ? "缩略图缓存已清理" : "清理缩略图缓存", subtitle: "保留原始照片与下载文件", symbol: cleared ? "checkmark.circle" : "arrow.triangle.2.circlepath", chevron: false)
                    }
                }

                DisclosureGroup("版本与使用说明", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("支持 iPhone、iPad（iOS 17 及以上）与 Mac（macOS 14 及以上）。群晖使用 DSM 7 / Synology Photos；OneDrive 使用微软授权登录。文件在设备与相应存储服务之间传输。")
                        Text(AppPlatform.isMac ? "支持本机照片管理与备份、群晖文件下载、视频播放和 NAS 状态查看。备份与下载需保持 App 运行；退出或休眠后暂停。暂不支持 QuickConnect 中继、视频转码与人脸识别。" : "支持新照片自动备份、照片管理、群晖文件浏览与下载、视频播放和 NAS 状态查看。备份可由系统安排后台补传；文件下载需保持 App 在前台。暂不支持 QuickConnect 中继、视频转码与人脸识别。")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                }.font(.subheadline).tint(.secondary).padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .padding(AppPlatform.isMac ? 28 : 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(NASStyle.canvas)
        .workspaceNavigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }

    private var rowDivider: some View { Divider().padding(.leading, 60) }

    private func preferencesSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var value: String? = nil
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(NASStyle.accent)
                .frame(width: 32, height: 34)
                .background(NASStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.caption).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct ConnectionView: View {
    var service: NASService = .photos
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var otp = ""
    @State private var forget = false
    private var connectionDescription: String {
        switch service {
        case .photos: return "填写 DSM 或 Photos 的 HTTPS 地址，使用具有照片访问权限的账号登录。"
        case .files: return "使用 NAS 账号连接 File Station，浏览并下载有权限的文件。"
        case .monitor: return "读取 CPU、内存、温度和磁盘状态。DSM 系统监控接口通常需要管理员权限；不具备权限的项目会显示提示。"
        }
    }
    private enum Field: Hashable { case address, username, password, otp }
    @FocusState private var focus: Field?
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.badge.wifi").font(.title3).foregroundStyle(NASStyle.accent)
                        .frame(width: 38, height: 38).background(NASStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("群晖连接").font(.headline)
                        Text(connectionDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
            }
            Section("服务器") {
                TextField("https://nas.example.com:5001", text: $app.credentials.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("nasAddress")
                    .focused($focus, equals: .address).submitLabel(.next).onSubmit { focus = .username }
                Text(service == .photos ? "也可使用 https://nas.example.com/photo。地址需从本机直接访问。" : "使用 DSM 的 HTTPS 地址，例如 https://nas.example.com:5001。").font(.caption).foregroundStyle(.secondary)
            }
            Section("登录信息") {
                TextField("账号", text: $app.credentials.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("nasUsername")
                    .focused($focus, equals: .username).submitLabel(.next).onSubmit { focus = .password }
                SecureField("密码", text: $app.credentials.password).textContentType(.password).accessibilityIdentifier("nasPassword")
                    .focused($focus, equals: .password).submitLabel(.done).onSubmit { focus = nil }
                TextField("验证码（开启双重验证时填写）", text: $otp).textContentType(.oneTimeCode).keyboardType(.numberPad).focused($focus, equals: .otp)
                Toggle("在系统钥匙串中保存登录信息", isOn: $app.remember)
                Text("保存后，照片、文件和状态在打开时自动恢复连接。主动断开后将暂停自动连接，直到再次登录。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = app.error { Section { ErrorBanner(message: error) } }
            Section {
                Button {
                    focus = nil
                    Task { if await app.connect(otp: otp, service: service) { otp = ""; dismiss() } }
                } label: {
                    HStack { Spacer(); if app.connecting { ProgressView() }; Text(app.connecting ? "正在验证连接…" : "登录并连接"); Spacer() }
                }.disabled(app.connecting || app.credentials.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.credentials.username.isEmpty || app.credentials.password.isEmpty).accessibilityIdentifier("loginNAS")
            } footer: {
                Text("账号密码通过加密连接提交。此版本不支持 QuickConnect 中继与交互式 Secure SignIn 审批，也不会跳过 HTTPS 证书校验。")
            }
            if app.client != nil || app.fileClient != nil || app.monitorClient != nil {
                Section { Button("断开连接", role: .destructive) { Task { await app.disconnect(); dismiss() } } }
            }
            if app.hasSavedConnection {
                Section { Button("移除保存的账号", role: .destructive) { forget = true } }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(NASStyle.canvas)
        .tint(NASStyle.accent)
        .navigationTitle(service == .photos ? "连接设置" : (service == .files ? "文件连接设置" : "状态连接设置")).navigationBarTitleDisplayMode(.inline)
            .onAppear { app.error = nil }
            .scrollDismissesKeyboard(.interactively)
            .disabled(app.connecting)
            .interactiveDismissDisabled(app.connecting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(app.connecting) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focus = nil } }
            }
            .confirmationDialog("移除本机保存的 NAS 登录信息？", isPresented: $forget, titleVisibility: .visible) {
                Button("移除并断开连接", role: .destructive) { Task { await app.forget(); otp = "" } }
            }
    }
}
