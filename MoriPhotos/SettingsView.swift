import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var backup: PhotoBackupManager
    @State private var cleared = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image("AppBrand").resizable().scaledToFit().frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) { Text("森空间").font(.title2.bold()); Text("你的私人数据空间").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
            Section("存储与连接") {
                NavigationLink { PhotoBackupView() } label: {
                    Label { HStack { Text("新照片备份"); Spacer(); Text(backup.configuration.enabled ? "已开启" : "未开启").foregroundStyle(.secondary).font(.caption) } } icon: { Image(systemName: "icloud.and.arrow.up") }
                }.accessibilityIdentifier("newPhotoBackupSettings")
                NavigationLink { ConnectionView() } label: {
                    Label { HStack { Text("Synology Photos"); Spacer(); Text(app.client == nil ? "未连接" : "已连接").foregroundStyle(.secondary).font(.caption) } } icon: { Image(systemName: "externaldrive") }
                }
                NavigationLink { ConnectionView(service: .files) } label: {
                    Label { HStack { Text("File Station"); Spacer(); Text(app.fileClient == nil ? "未连接" : "已连接").foregroundStyle(.secondary).font(.caption) } } icon: { Image(systemName: "folder") }
                }
                NavigationLink { NASMonitorHomeView() } label: {
                    Label("NAS 运行状态", systemImage: "waveform.path.ecg")
                }
                Button {
                    library.manager.stopCachingImagesForAllAssets()
                    Task { await app.client?.clearCache(); cleared = true }
                } label: { Label(cleared ? "缩略图缓存已清理" : "清理缩略图缓存", systemImage: "arrow.triangle.2.circlepath") }
            }
            Section("照片权限") {
                LabeledContent(AppPlatform.libraryName, value: library.canRead ? (library.authorization == .limited ? "部分照片" : "全部照片") : "未授权")
                Button("打开系统权限设置") { AppPlatform.openPhotoSettings() }
            }
            Section("关于这一版") {
                LabeledContent("版本", value: "0.10.0 · 个人使用版").accessibilityIdentifier("appVersion")
                Text("支持 iPhone、iPad（iOS 17 及以上）与 Mac（macOS 14 及以上）。群晖使用 DSM 7 / Synology Photos，可直连 HTTPS 地址。照片在设备与 NAS 间传输。").font(.footnote).foregroundStyle(.secondary)
                Text(AppPlatform.isMac ? "支持本机照片管理与备份、群晖文件下载、视频播放和 NAS 状态查看。备份与下载需保持 App 运行；退出或休眠后暂停。暂不支持 QuickConnect 中继、视频转码与人脸识别。" : "支持新照片自动备份、照片管理、群晖文件浏览与下载、视频播放和 NAS 状态查看。备份可由系统安排后台补传；文件下载需保持 App 在前台。暂不支持 QuickConnect 中继、视频转码与人脸识别。").font(.footnote).foregroundStyle(.secondary)
            }
        }.workspaceNavigationTitle("设置")
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
                VStack(alignment: .leading, spacing: 10) {
                    Label("连接你的群晖", systemImage: "externaldrive.badge.wifi").font(.title2.bold()).foregroundStyle(Theme.accent)
                    Text(connectionDescription).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
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
        }.navigationTitle(service == .photos ? "连接设置" : (service == .files ? "文件连接设置" : "状态连接设置")).navigationBarTitleDisplayMode(.inline)
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
