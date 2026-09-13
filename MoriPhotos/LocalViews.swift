import SwiftUI
import Photos

struct LocalLibraryView: View {
    var isActive = true
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filter = "全部"
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var detail: LocalPhotoSelection?
    @State private var showDelete = false
    @State private var showLimited = false
    @State private var busy = false
    private var source: [PHAsset] { library.assets }
    private var visible: [PHAsset] {
        source.filter { filter == "收藏" ? $0.isFavorite : filter == "截图" ? $0.mediaSubtypes.contains(.photoScreenshot) : true }
    }
    private var chosen: [PHAsset] { source.filter { selected.contains($0.localIdentifier) } }
    @AppStorage("desktopThumbnailSize") private var thumbnailSize = 170.0
    private var columns: [GridItem] {
        AppPlatform.isMac || horizontalSizeClass == .regular
            ? [GridItem(.adaptive(minimum: AppPlatform.isMac ? thumbnailSize : 160), spacing: 2)]
            : Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !library.canRead {
                    accessView.padding(.horizontal, 20)
                } else {
                    if library.authorization == .limited {
                        Button { showLimited = true } label: {
                            Label("当前仅显示已授权照片 · 管理访问范围", systemImage: "hand.raised")
                                .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding()
                                .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        }.padding(.horizontal, 20)
                    }
                    HStack {
                        Picker("照片筛选", selection: $filter) {
                            ForEach(["全部", "收藏", "截图"], id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: AppPlatform.isMac ? 320 : .infinity)
                        if AppPlatform.isMac { Spacer(); thumbnailControl }
                    }.padding(.horizontal, 20)
                    HStack {
                        Text(selecting ? "已选择 \(selected.count) 张" : filter == "全部" ? "所有照片" : filter).font(.headline)
                        Spacer()
                        if selecting {
                            Button("全选") { selected = Set(visible.map(\.localIdentifier)) }.font(.subheadline)
                        }
                        Text("\(visible.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20)
                    if visible.isEmpty {
                        EmptyCard(icon: "photo.on.rectangle.angled", title: "这里还没有照片", message: filter == "收藏" ? "打开一张照片，轻点爱心即可收藏。" : "拍下新的回忆，或从群晖保存照片后再来看看。")
                            .padding(.horizontal, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(visible, id: \.localIdentifier) { asset in
                                Button {
                                    if selecting {
                                        if selected.contains(asset.localIdentifier) { selected.remove(asset.localIdentifier) }
                                        else { selected.insert(asset.localIdentifier) }
                                    } else { detail = LocalPhotoSelection(assets: visible, selectedID: asset.localIdentifier) }
                                } label: {
                                    GeometryReader { proxy in
                                        AssetImage(asset: asset).frame(width: proxy.size.width, height: proxy.size.height)
                                            .overlay(alignment: .bottomTrailing) {
                                                if selecting {
                                                    Image(systemName: selected.contains(asset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                                                        .font(.title2).foregroundStyle(.white, Theme.accent).shadow(radius: 2).padding(8)
                                                } else if asset.isFavorite {
                                                    Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2).padding(8)
                                                }
                                            }
                                    }.aspectRatio(1, contentMode: .fit).clipped()
                                }.buttonStyle(.plain).accessibilityLabel("照片 \(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                                    .accessibilityIdentifier("localPhotoCell")
                            }
                        }
                    }
                }
            }.padding(.vertical, 12)
        }
        .background(Theme.canvas)
        .workspaceNavigationTitle("森空间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isActive && library.canRead {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "完成" : "选择") { selecting.toggle(); selected.removeAll() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 32) {
                    Button { run { await library.favorite(chosen, value: true) } } label: { Label("收藏", systemImage: "heart") }
                    Button(role: .destructive) { showDelete = true } label: { Label("删除", systemImage: "trash") }
                }.font(.subheadline).frame(maxWidth: .infinity).padding().background(.regularMaterial)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .sheet(item: $detail) { selection in LocalDetailView(selection: selection).desktopSheet(width: 1000, height: 680) }
        .sheet(isPresented: $showLimited, onDismiss: library.reload) {
            NavigationStack { LimitedPicker().navigationTitle("管理照片访问").toolbar { Button("完成") { showLimited = false } } }
        }
        .confirmationDialog("删除 \(selected.count) 张照片？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("从系统照片图库删除", role: .destructive) { run { if await library.delete(chosen) { selected.removeAll(); selecting = false } } }
        } message: { Text("照片将进入系统“最近删除”。如开启了 iCloud 照片，此操作也会同步到其他设备。") }
        .alert("操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好") { library.error = nil } } message: { Text(library.error ?? "") }
        .onChange(of: library.assets.map(\.localIdentifier)) { _, ids in selected.formIntersection(Set(ids)) }
    }
    private var thumbnailControl: some View {
        HStack { Image(systemName: "square.grid.3x3"); Slider(value: $thumbnailSize, in: 110...280).frame(width: 120).accessibilityLabel("缩略图大小") }.foregroundStyle(.secondary)
    }
    private var accessView: some View {
        VStack(spacing: 12) {
            EmptyCard(icon: "photo.stack", title: "从你的照片开始", message: "选择要分享给森空间的照片，\n或允许访问全部图库，开始整理回忆。")
            if library.authorization == .notDetermined {
                Button { Task { await library.requestAccess() } } label: { Text("开启照片访问").frame(maxWidth: .infinity).padding(.vertical, 7) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("grantPhotos")
            } else {
                Button("前往系统设置") { AppPlatform.openPhotoSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 26))
    }
    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task { await action(); busy = false }
    }
}

struct LocalPhotoSelection: Identifiable {
    let assets: [PHAsset]
    let selectedID: String
    var id: String { selectedID }
}

struct LocalDetailView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fileSize = PhotoFileSizeLoader()
    @State private var assets: [PHAsset]
    @State private var index: Int
    @State private var showDelete = false
    @State private var busy = false
    init(selection: LocalPhotoSelection) {
        _assets = State(initialValue: selection.assets)
        _index = State(initialValue: selection.assets.firstIndex { $0.localIdentifier == selection.selectedID } ?? 0)
    }
    private var current: PHAsset? {
        guard assets.indices.contains(index) else { return nil }
        let asset = assets[index]
        return library.assets.first { $0.localIdentifier == asset.localIdentifier } ?? asset
    }
    var body: some View {
        NavigationStack {
            Group {
                if AppPlatform.isMac {
                    HStack(spacing: 0) {
                        LocalPhotoPager(assets: assets, library: library, index: $index, enabled: !busy).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        information.frame(width: 280)
                    }
                } else {
                    VStack(spacing: 0) {
                        LocalPhotoPager(assets: assets, library: library, index: $index, enabled: !busy).frame(maxWidth: .infinity, maxHeight: .infinity)
                        information
                    }
                }
            }
            .navigationTitle("照片").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .confirmationDialog("从系统图库删除这张照片？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除照片", role: .destructive) {
                    guard let current else { return }
                    busy = true
                    Task { if await library.delete([current]) { dismiss() }; busy = false }
                }
            } message: { Text("照片将进入系统“最近删除”，并可能同步删除 iCloud 中的副本。") }
            .alert("操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好") { library.error = nil } } message: { Text(library.error ?? "") }
            .onChange(of: library.assets.map(\.localIdentifier)) { _, ids in
                let selectedID = current?.localIdentifier
                let allowed = Set(ids)
                assets.removeAll { !allowed.contains($0.localIdentifier) }
                if assets.isEmpty { dismiss() }
                else { index = assets.firstIndex { $0.localIdentifier == selectedID } ?? min(index, assets.count - 1) }
            }
        }
    }
    @ViewBuilder private var information: some View {
                if let current {
                    VStack(spacing: 8) {
                        HStack {
                            Button { if index > 0 { index -= 1 } } label: { Label("上一张", systemImage: "chevron.left").labelStyle(.iconOnly).frame(width: 48, height: 44) }
                                .disabled(index == 0 || busy).keyboardShortcut(.leftArrow, modifiers: []).accessibilityIdentifier("previousPhoto")
                            Spacer()
                            Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit()).accessibilityIdentifier("photoPosition")
                            Spacer()
                            Button { if index + 1 < assets.count { index += 1 } } label: { Label("下一张", systemImage: "chevron.right").labelStyle(.iconOnly).frame(width: 48, height: 44) }
                                .disabled(index == assets.count - 1 || busy).keyboardShortcut(.rightArrow, modifiers: []).accessibilityIdentifier("nextPhoto")
                        }.padding(.horizontal, 20)
                        Text(current.creationDate?.formatted(date: .long, time: .shortened) ?? "照片").font(.subheadline)
                        HStack(spacing: 6) {
                            Text("\(current.pixelWidth) × \(current.pixelHeight)")
                            Text("·")
                            LocalPhotoFileSizeLabel(asset: current, loader: fileSize)
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 16)
                        HStack(spacing: 50) {
                            Button { busy = true; Task { await library.favorite([current], value: !current.isFavorite); busy = false } } label: { Image(systemName: current.isFavorite ? "heart.fill" : "heart") }.accessibilityLabel("收藏照片")
                            Button(role: .destructive) { showDelete = true } label: { Image(systemName: "trash") }.accessibilityLabel("删除照片")
                        }.font(.title2).padding().disabled(busy)
                    }.padding(.top, 16)
                }
    }

}
