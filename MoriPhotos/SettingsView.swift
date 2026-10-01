import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var backup: PhotoBackupManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var cleared = false
    @State private var showDetails = false

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !AppPlatform.isMac && sizeClass != .regular {
                        HStack(spacing: 12) {
                            Text("设置").font(.system(size: 26, weight: .semibold))
                            Spacer()
                            Image("AppBrand").resizable().scaledToFit().frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                        }.padding(.bottom, 2)
                    }
                    if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 24) {
                                connections
                                backupAndDevices
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 24) {
                                localPreferences
                                about
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            connections
                            backupAndDevices
                            localPreferences
                            about
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(AppPlatform.isMac ? 28 : 20)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity, alignment: .top)
            }.phoneMenuScrolling()
            .background(NASStyle.canvas)
        }
        .workspaceNavigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar(AppPlatform.isMac || sizeClass == .regular ? .automatic : .hidden, for: .navigationBar)
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("存储连接")
            VStack(spacing: 0) {
                NavigationLink { ConnectionView().toolbar(.visible, for: .navigationBar) } label: {
                    SettingsServiceCard(title: "群晖照片", symbol: "photo.on.rectangle", connected: app.client != nil)
                }
                rowDivider
                NavigationLink { ConnectionView(service: .files).toolbar(.visible, for: .navigationBar) } label: {
                    SettingsServiceCard(title: "群晖文件", symbol: "folder", connected: app.fileClient != nil)
                }

            }.padding(.horizontal, 16).settingsPanel()
        }
    }

    private var backupAndDevices: some View {
        preferencesSection("备份与工具") {
            NavigationLink { PhotoBackupView().toolbar(.visible, for: .navigationBar) } label: {
                SettingsRow(title: "新照片备份", subtitle: "原图保存到群晖", symbol: "arrow.up.doc", value: backup.configuration.enabled ? "已开启" : "未开启")
            }.accessibilityIdentifier("newPhotoBackupSettings")
            rowDivider
            NavigationLink { NASMonitorHomeView().toolbar(.visible, for: .navigationBar) } label: {
                SettingsRow(title: "NAS 运行状态", subtitle: "负载、容量与硬盘健康", symbol: "waveform.path.ecg")
            }

        }
    }

    private var localPreferences: some View {
        preferencesSection("本机偏好") {
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
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("关于")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image("AppBrand").resizable().scaledToFit().frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppBrand.name).font(.subheadline.weight(.semibold))
                        Text("版本 \(version) · 个人使用版").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("appVersion")
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 4)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("支持 iPhone、iPad（iOS 17 及以上）与 Mac（macOS 14 及以上）。群晖使用 DSM 7 / Synology Photos。文件在设备与相应存储服务之间传输。")
                        Text(AppPlatform.isMac ? "支持本机照片管理与备份、群晖文件下载、视频播放和 NAS 状态查看。备份与下载需保持 App 运行；退出或休眠后暂停。暂不支持 QuickConnect 中继、视频转码与人脸识别。" : "支持新照片自动备份、照片管理、群晖文件浏览与下载、视频播放和 NAS 状态查看。备份可由系统安排后台补传；文件下载需保持 App 在前台。暂不支持 QuickConnect 中继、视频转码与人脸识别。")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                } label: { Text("版本与使用说明").frame(minHeight: 44) }
                    .font(.subheadline).tint(.secondary)
            }.padding(16).settingsPanel()
        }
    }

    private var rowDivider: some View { Rectangle().fill(NASStyle.outline).frame(height: 1).padding(.leading, 44) }

    private func sectionTitle(_ title: String) -> some View {
        MoriSectionHeading(title).padding(.horizontal, 4)
    }

    private func preferencesSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            VStack(spacing: 0, content: content).padding(.horizontal, 16).settingsPanel()
        }
    }
}

private struct SettingsServiceCard: View {
    let title: String
    let symbol: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(NASStyle.accent)
                .frame(width: 36, height: 36).background(NASStyle.selection, in: RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(connected ? NASStyle.accent : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                Text(connected ? "已连接" : "未连接").font(.caption).foregroundStyle(connected ? NASStyle.accent : .secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
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
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(NASStyle.accent)
                .frame(width: 32, height: 32)
                .background(NASStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.caption.weight(.medium)).foregroundStyle(value == "已连接" || value == "已开启" ? NASStyle.accent : .secondary) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
    }
}

private extension View {
    func settingsPanel() -> some View {
        moriPanel()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: service == .photos ? "photo.on.rectangle" : (service == .files ? "folder" : "waveform.path.ecg"))
                        .font(.system(size: 22, weight: .regular)).foregroundStyle(NASStyle.accent)
                        .frame(width: 42, height: 42).background(NASStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(service == .photos ? "Synology Photos" : (service == .files ? "File Station" : "NAS 运行状态"))
                            .font(.system(size: 24, weight: .semibold)).foregroundStyle(.primary)
                        Text(connectionDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)

                connectionSection("服务器") {
                    TextField("https://nas.example.com:5001", text: $app.credentials.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("nasAddress")
                        .focused($focus, equals: .address).submitLabel(.next).onSubmit { focus = .username }
                        .connectionInput()
                    Text(service == .photos ? "也可使用 /photo 地址。需从本机直接访问，暂不支持 QuickConnect 中继。" : "使用可从本机直接访问的 DSM HTTPS 地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(app.connecting)
                connectionSection("登录信息") {
                    VStack(spacing: 0) {
                        TextField("账号", text: $app.credentials.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("nasUsername")
                            .focused($focus, equals: .username).submitLabel(.next).onSubmit { focus = .password }
                            .padding(16).frame(minHeight: 50)
                        inputRule
                        SecureField("密码", text: $app.credentials.password).textContentType(.password).accessibilityIdentifier("nasPassword")
                            .focused($focus, equals: .password).submitLabel(.done).onSubmit { focus = nil }
                            .padding(16).frame(minHeight: 50)
                        inputRule
                        TextField("验证码（开启双重验证时填写）", text: $otp).textContentType(.oneTimeCode).keyboardType(.numberPad).focused($focus, equals: .otp)
                            .padding(16).frame(minHeight: 50)
                    }.textFieldStyle(.plain).background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(NASStyle.outline, lineWidth: 0.5) }
                    Toggle("在钥匙串中保存登录信息", isOn: $app.remember).font(.subheadline).frame(minHeight: 44)
                    Text("保存后自动恢复照片、文件和状态连接；主动断开后暂停自动连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(app.connecting)
                if let error = app.error { ErrorBanner(message: error) }
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        focus = nil
                        Task { if await app.connect(otp: otp, service: service) { otp = ""; dismiss() } }
                    } label: {
                        HStack {
                            if app.connecting { ProgressView().tint(.white) }
                            Text(app.connecting ? (app.connectionPhase?.title ?? "正在连接…") : "登录并连接").font(.headline)
                        }.padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: 50).foregroundStyle(.white)
                            .background(NASStyle.signal, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .disabled(app.connecting || app.credentials.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.credentials.username.isEmpty || app.credentials.password.isEmpty).accessibilityIdentifier("loginNAS")
                    if app.connecting {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app.connectionPhase?.detail ?? "正在准备连接。")
                                .font(.subheadline).accessibilityIdentifier("nasConnectionPhase")
                            Text("最多等待 30 秒，可随时取消。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("取消连接") { app.cancelConnection() }
                                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                                .accessibilityIdentifier("cancelNASConnection")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("账号密码通过加密连接提交。此版本不支持 QuickConnect 中继与交互式 Secure SignIn 审批，也不会跳过 HTTPS 证书校验。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if app.client != nil || app.fileClient != nil || app.monitorClient != nil {
                    Button("断开连接", role: .destructive) { Task { await app.disconnect(); dismiss() } }.frame(minHeight: 44).disabled(app.connecting)
                }
                if app.hasSavedConnection {
                    Button("移除保存的账号", role: .destructive) { forget = true }.frame(minHeight: 44).disabled(app.connecting)
                }
            }.padding(AppPlatform.isMac ? 28 : 20).frame(maxWidth: 660).frame(maxWidth: .infinity)
        }.phoneMenuScrolling()
        .background(NASStyle.canvas)
        .tint(NASStyle.accent)
        .navigationTitle(service == .photos ? "连接设置" : (service == .files ? "文件连接设置" : "状态连接设置")).navigationBarTitleDisplayMode(.inline)
            .onAppear { app.error = nil }
            .onDisappear { app.cancelConnection() }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(app.connecting ? "取消" : "完成") { app.cancelConnection(); dismiss() }
                        .accessibilityIdentifier("dismissNASConnection")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focus = nil } }
            }
            .confirmationDialog("移除本机保存的 NAS 登录信息？", isPresented: $forget, titleVisibility: .visible) {
                Button("移除并断开连接", role: .destructive) { Task { await app.forget(); otp = "" } }
            }
    }
    private var inputRule: some View {
        Rectangle().fill(NASStyle.outline).frame(height: 1).padding(.horizontal, 16)
    }

    private func connectionSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

}

private extension View {
    func connectionInput() -> some View {
        textFieldStyle(.plain).padding(16).frame(minHeight: 50)
            .background(NASStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(NASStyle.outline, lineWidth: 0.5) }
    }
}
