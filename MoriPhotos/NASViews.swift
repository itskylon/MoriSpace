import SwiftUI

struct NASHomeView: View {
    @State private var section = "照片"
    @State private var visited: Set<String> = ["照片"]
    private var selection: Binding<String> {
        Binding(get: { section }, set: { next in
            visited.insert(next)
            section = next
        })
    }
    var body: some View {
        ZStack {
            NASPhotosHomeView(isActive: section == "照片")
                .nasPageVisibility(section == "照片")
            if visited.contains("文件") {
                NASFilesHomeView(isActive: section == "文件")
                    .nasPageVisibility(section == "文件")
            }
            if visited.contains("状态") {
                NASMonitorHomeView(isActive: section == "状态")
                    .nasPageVisibility(section == "状态")
            }
        }.navigationTitle("群晖").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { NASSectionTabs(selection: selection) } }
            .toolbarBackground(NASStyle.canvas, for: .navigationBar)
    }
}

private extension View {
    func nasPageVisibility(_ active: Bool) -> some View {
        opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active).zIndex(active ? 1 : 0)
    }
}

struct NASPhotosHomeView: View {
    var isActive = true
    @EnvironmentObject private var app: AppState
    @State private var connect = false
    var body: some View {
        Group {
            if let client = app.client {
                NASBrowserView(client: client, isActive: isActive).id(app.connectionID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        NASConnectionStatus(service: .photos)
                        Button { connect = true } label: {
                            NASActionLabel(title: app.hasSavedConnection ? "连接设置" : "连接群晖照片", subtitle: "Synology Photos", symbol: "photo.stack")
                        }.buttonStyle(.plain).accessibilityIdentifier("connectNAS")
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }.background(NASStyle.canvas)
            }
        }.sheet(isPresented: $connect) { NavigationStack { ConnectionView() }.desktopSheet() }
            .task(id: isActive) { if isActive { await app.restoreConnection(service: .photos) } }
    }
}

struct NASConnectionStatus: View {
    @EnvironmentObject private var app: AppState
    let service: NASService
    var body: some View {
        if app.restoringService == service {
            ProgressView("正在恢复连接…").padding().accessibilityIdentifier("restoringNAS")
        } else if let error = app.restoreErrors[service] {
            ErrorBanner(message: error)
            Button("重试连接") { Task { await app.restoreConnection(service: service, retry: true) } }
                .buttonStyle(.bordered)
        }
    }
}

struct NASBrowserView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var folderRowHeight = 48
    let client: SynologyClient
    var isActive = true
    var folder: NASFolder? = nil
    var initialSpace: PhotoSpace = .personal
    @State private var space: PhotoSpace = .personal
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @StateObject private var store = NASBrowserStore()
    @State private var selected: NASPhoto?
    @State private var settings = false
    private var filteredPhotos: [NASPhoto] { store.photos.filter { query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) } }
    private var filteredFolders: [NASFolder] { store.folders.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    private var effectiveSpace: PhotoSpace { folder == nil ? space : initialSpace }
    @AppStorage("desktopThumbnailSize") private var thumbnailSize = 170.0
    private var columns: [GridItem] {
        AppPlatform.isMac || horizontalSizeClass == .regular
            ? [GridItem(.adaptive(minimum: AppPlatform.isMac ? thumbnailSize : 160), spacing: 2)]
            : Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                browserControls
                if showingSearch { searchField }
                if let error = store.error {
                    ErrorBanner(message: error).padding(.horizontal, 20)
                    Button("重试") { Task { await store.reset(client: client, space: effectiveSpace, folder: folder?.id) } }.buttonStyle(.bordered).padding(.horizontal, 20)
                }
                if !filteredFolders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(filteredFolders) { child in
                                NavigationLink { NASBrowserView(client: client, folder: child, initialSpace: effectiveSpace) } label: {
                                    NASFolderChip(title: child.title)
                                }.buttonStyle(.plain).accessibilityIdentifier("nasPhotoFolder_\(child.id)")
                            }
                        }
                        .padding(.horizontal, 16)
                    }.frame(height: folderRowHeight)
                }
                HStack {
                    Text("\(filteredPhotos.count) 张照片").font(.caption.weight(.medium))
                    Spacer()
                    Text(query.isEmpty ? "最新优先" : "匹配已载入内容").font(.caption)
                }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 2)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredPhotos) { photo in
                        Button { selected = photo } label: {
                            GeometryReader { proxy in
                                NASImage(client: client, photo: photo, space: effectiveSpace)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .overlay(alignment: .bottomLeading) {
                                        if photo.isVideo { Image(systemName: "video.fill").foregroundStyle(.white).shadow(radius: 2).padding(8) }
                                    }
                            }.aspectRatio(1, contentMode: .fit).clipped()
                        }.buttonStyle(.plain).accessibilityLabel(photo.filename).accessibilityIdentifier("nasPhotoCell")
                    }
                }
                if store.loading { ProgressView("正在读取 NAS…").frame(maxWidth: .infinity).padding(30) }
                else if store.hasMore && store.error == nil {
                    Button("载入更多照片") { Task { await store.loadMore(client: client, space: effectiveSpace, folder: folder?.id) } }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity).padding()
                }
                if !store.loading && store.error == nil && filteredPhotos.isEmpty && filteredFolders.isEmpty {
                    EmptyCard(icon: query.isEmpty ? "photo.on.rectangle" : "magnifyingglass", title: query.isEmpty ? "这个空间还没有照片" : "没有找到匹配内容", message: query.isEmpty ? "请检查 Photos 索引、空间选择和账号的访问权限。" : "搜索范围为已载入的照片与文件夹，可继续载入更多。")
                        .padding(.horizontal, 20)
                }
            }.padding(.top, 2).padding(.bottom, 12)
        }.background(NASStyle.canvas)
            .workspaceNavigationTitle(folder?.title ?? "群晖", detail: folder != nil).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if folder == nil && isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").foregroundStyle(Color.primary) }.accessibilityLabel("连接设置")
                    }
                }
            }
            .onChange(of: isActive) { _, active in if !active { searchFocused = false } }
            .task(id: effectiveSpace) { selected = nil; await store.reset(client: client, space: effectiveSpace, folder: folder?.id) }
            .refreshable { await store.reset(client: client, space: effectiveSpace, folder: folder?.id) }
            .sheet(item: $selected) { photo in NASDetailView(client: client, photo: photo, space: effectiveSpace, gallery: filteredPhotos).desktopSheet(width: 1000, height: 680) }
            .sheet(isPresented: $settings) { NavigationStack { ConnectionView() }.desktopSheet() }
    }

    private var browserControls: some View {
        HStack(spacing: 12) {
            if folder == nil {
                Menu {
                    ForEach(PhotoSpace.allCases) { option in
                        Button { space = option } label: {
                            if space == option { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }.accessibilityIdentifier("nasSpace_\(option.rawValue)")
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: space == .personal ? "person.crop.square" : "person.2").foregroundStyle(NASStyle.accent)
                        Text(space.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.tint(NASStyle.accent).accessibilityIdentifier("nasSpaceMenu")
            } else {
                Text(effectiveSpace.title).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if AppPlatform.isMac {
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 110...280).frame(width: 120).accessibilityLabel("缩略图大小")
                Button { Task { await store.reset(client: client, space: effectiveSpace, folder: folder?.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r").help("刷新照片 ⌘R").disabled(store.loading)
            }
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    showingSearch.toggle()
                    if !showingSearch { query = "" }
                }
                searchFocused = showingSearch
            } label: {
                Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(showingSearch ? "关闭搜索" : "搜索照片和文件夹").accessibilityIdentifier("toggleNASSearch")
        }.padding(.leading, 16).padding(.trailing, 8)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索已载入内容", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused).onSubmit { searchFocused = false }
                .accessibilityIdentifier("nasPhotoSearch")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("清空搜索").accessibilityIdentifier("clearNASSearch")
            }
        }.font(.subheadline).padding(12)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
            .padding(.horizontal, 16)
    }
}

struct NASImage: View {
    let client: SynologyClient
    let photo: NASPhoto
    let space: PhotoSpace
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Theme.accent.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView().tint(Theme.accent) }
        }.clipped().task(id: "\(space.rawValue)-\(photo.id)") {
            image = nil; failed = false
            do { let result = try await client.thumbnail(photo, space: space); if !Task.isCancelled { image = result } }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct NASDetailView: View {
    let client: SynologyClient
    @State var photo: NASPhoto
    let space: PhotoSpace
    var gallery: [NASPhoto] = []
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var saving = false
    @State private var saved = false
    private var index: Int { gallery.firstIndex { $0.id == photo.id } ?? 0 }
    var body: some View {
        NavigationStack {
            Group {
                if AppPlatform.isMac {
                    HStack(spacing: 0) {
                        preview
                        Divider()
                        information.frame(width: 260)
                    }
                } else { VStack(spacing: 16) { preview; information } }
            }
            .navigationTitle(photo.filename).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .task(id: photo.id) { saved = false; image = nil; await load() }
        }
    }
    private var preview: some View {
        Group {
            if let image { ZoomableImage(image: image, onPrevious: { if index > 0 && !saving { photo = gallery[index - 1] } }, onNext: { if index + 1 < gallery.count && !saving { photo = gallery[index + 1] } }).id(photo.id) }
            else if error == nil { ProgressView("正在加载预览…") }
            else { Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.04))
    }
    private var information: some View {
        VStack(spacing: 16) {
            if AppPlatform.isMac { Spacer() }
            Text(photo.filename).font(.headline).lineLimit(3)
            if let date = photo.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            Text(PhotoFileSize.text(photo.filesize).map { (photo.isVideo ? "文件 " : "原图 ") + $0 } ?? "大小暂不可用")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("nasPhotoFileSize")
            if gallery.count > 1 {
                HStack {
                    Button { photo = gallery[index - 1] } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0 || saving).keyboardShortcut(.leftArrow, modifiers: []).accessibilityIdentifier("previousNASPhoto").help("上一张 ←")
                    Spacer()
                    Text("\(index + 1) / \(gallery.count)").font(.caption.monospacedDigit()).accessibilityIdentifier("nasPhotoPosition")
                    Spacer()
                    Button { photo = gallery[index + 1] } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= gallery.count - 1 || saving).keyboardShortcut(.rightArrow, modifiers: []).accessibilityIdentifier("nextNASPhoto").help("下一张 →")
                }
            }
            if let error { ErrorBanner(message: error); Button("重新加载预览") { Task { await load() } } }
            if photo.isVideo { Text("这里显示视频封面，可在群晖文件中打开并播放原视频。").font(.footnote).foregroundStyle(.secondary) }
            else {
                Button { Task { await save() } } label: {
                    HStack {
                        if saving { ProgressView() }
                        Label(saved ? "已保存到图库" : "保存原图到图库", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }.frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).disabled(saving || saved)
            }
            if AppPlatform.isMac {
                Text("双击或触控板缩放\n⌘ + / − 缩放 · ⌘ 0 适合窗口").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
        }.padding(20)
    }
    private func load() async {
        error = nil
        let id = photo.id
        do {
            let loaded = try await client.thumbnail(photo, space: space, large: true)
            if !Task.isCancelled && photo.id == id { image = loaded }
        } catch { if !Task.isCancelled && photo.id == id { self.error = friendlyError(error) } }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            let file = try await client.original(photo, space: space)
            defer { try? FileManager.default.removeItem(at: file) }
            try await library.save(file: file)
            saved = true
        } catch { self.error = friendlyError(error) }
    }
}
