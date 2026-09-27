import SwiftUI
import Photos

struct LocalLibraryView: View {
    var isActive = true
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter = "全部"
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var detail: LocalPhotoSelection?
    @State private var showDelete = false
    @State private var showLimited = false
    @State private var busy = false
    private var wide: Bool { AppPlatform.isMac || horizontalSizeClass == .regular }
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
        VStack(spacing: 0) {
            if !wide { phoneHeader }
            if library.canRead { libraryToolbar }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !library.canRead {
                        accessView.frame(maxWidth: 460).frame(maxWidth: .infinity).padding(20)
                    } else {
                        if library.authorization == .limited {
                            Button { showLimited = true } label: {
                                Label("仅显示已授权照片 · 管理访问范围", systemImage: "hand.raised")
                                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            }.padding(.horizontal, 16)
                        }
                        if visible.isEmpty {
                            EmptyCard(icon: "photo.on.rectangle.angled", title: "这里还没有照片", message: filter == "收藏" ? "打开一张照片，轻点爱心即可收藏。" : "拍摄照片，或从群晖保存到本机后，就会显示在这里。")
                                .padding(.top, 28)
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
                                                        Image(systemName: "heart.fill").font(.footnote).foregroundStyle(.white).shadow(radius: 2).padding(8)
                                                    }
                                                }
                                        }.aspectRatio(1, contentMode: .fit).clipped()
                                    }.buttonStyle(.plain).accessibilityLabel("照片 \(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                                        .accessibilityIdentifier("localPhotoCell")
                                }
                            }.padding(.horizontal, AppPlatform.isMac ? 16 : 0)
                        }
                    }
                }.padding(.top, library.canRead ? (wide ? 12 : 2) : 0)
            }
        }
        .background(Theme.canvas)
        .workspaceNavigationTitle("照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(wide ? .automatic : .hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 32) {
                    Button { run { await library.favorite(chosen, value: true) } } label: { Label("收藏", systemImage: "heart") }
                    Button(role: .destructive) { showDelete = true } label: { Label("删除", systemImage: "trash") }
                }.font(.subheadline).frame(maxWidth: .infinity).padding().background(.regularMaterial)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .modifier(LocalPhotoPresentation(selection: $detail, wide: wide))
        .sheet(isPresented: $showLimited, onDismiss: library.reload) {
            NavigationStack { LimitedPicker().navigationTitle("管理照片访问").toolbar { Button("完成") { showLimited = false } } }
        }
        .confirmationDialog("删除 \(selected.count) 张照片？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("从系统照片图库删除", role: .destructive) { run { if await library.delete(chosen) { selected.removeAll(); selecting = false } } }
        } message: { Text("照片将进入系统“最近删除”。如开启了 iCloud 照片，此操作也会同步到其他设备。") }
        .alert("操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好") { library.error = nil } } message: { Text(library.error ?? "") }
        .onChange(of: library.assets.map(\.localIdentifier)) { _, ids in selected.formIntersection(Set(ids)) }
    }
    private var phoneHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                libraryTitle
                if library.canRead {
                    HStack(spacing: 8) { photoCountBadge; Spacer(minLength: 4); selectionButton }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    libraryTitle
                    if library.canRead { photoCountBadge }
                    Spacer(minLength: 6)
                    if library.canRead { selectionButton }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(NASStyle.signal)
    }
    private var libraryTitle: some View {
        Text("照片").font(.largeTitle.weight(.black)).tracking(-1.5)
            .foregroundStyle(NASStyle.ink).accessibilityIdentifier("localLibraryTitle")
    }
    private var photoCountBadge: some View {
        Text("\(visible.count)").font(.caption.weight(.heavy).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(NASStyle.signal).padding(.horizontal, 9).padding(.vertical, 6)
            .background(NASStyle.ink, in: Capsule())
            .accessibilityLabel("\(visible.count) 张照片")
    }
    private var selectionButton: some View {
        Button { selecting.toggle(); selected.removeAll() } label: {
            HStack(spacing: 6) {
                Image(systemName: selecting ? "checkmark" : "checkmark.circle")
                Text(selecting ? "完成" : "选择")
            }.font(.subheadline.weight(.bold)).padding(.horizontal, 13).frame(minHeight: 44)
                .foregroundStyle(NASStyle.signal)
                .background(NASStyle.ink, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("localPhotoSelection")
    }
    private var libraryToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                MoriFilterBar(titles: ["全部", "收藏", "截图"], selection: $filter)
                Spacer(minLength: 8)
                if wide || selecting { libraryCount }
                if AppPlatform.isMac { thumbnailControl.padding(.leading, 16) }
                if wide { selectionButton.padding(.leading, 12) }
            }
            VStack(alignment: .leading, spacing: 4) {
                MoriFilterBar(titles: ["全部", "收藏", "截图"], selection: $filter)
                if wide || selecting { libraryCount }
                if AppPlatform.isMac { thumbnailControl }
                if wide { selectionButton }
            }
        }.padding(.horizontal, 16).padding(.top, wide ? 12 : 10)
            .padding(.bottom, 10).background(NASStyle.canvas)
    }
    private var libraryCount: some View {
        HStack(spacing: 10) {
            Text(selecting ? "已选 \(selected.count) 张" : "\(visible.count) 张照片")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            if selecting {
                Button("全选") { selected = Set(visible.map(\.localIdentifier)) }
                    .font(.subheadline).frame(minHeight: 44)
            }
        }
    }
    private var thumbnailControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3").font(.caption)
            Slider(value: $thumbnailSize, in: 110...280).frame(width: 100).accessibilityLabel("缩略图大小")
        }.foregroundStyle(.secondary)
    }
    private var accessView: some View {
        VStack(spacing: 4) {
            EmptyCard(icon: "photo.stack", title: "你的照片，在这里", message: "允许访问照片图库，即可浏览、收藏和整理本机照片。也可以只选择部分照片。")
            if library.authorization == .notDetermined {
                Button { Task { await library.requestAccess() } } label: { Text("开启照片访问").padding(.horizontal, 16).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("grantPhotos")
            } else {
                Button("前往系统设置") { AppPlatform.openPhotoSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(.vertical, 30).frame(maxWidth: .infinity)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 28))
    }
    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task { await action(); busy = false }
    }
}

private struct LocalPhotoPresentation: ViewModifier {
    @Binding var selection: LocalPhotoSelection?
    let wide: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if wide {
            content.sheet(item: $selection) { LocalDetailView(selection: $0).desktopSheet(width: 1000, height: 680) }
        } else {
            content.fullScreenCover(item: $selection) { LocalDetailView(selection: $0) }
        }
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
                        LocalPhotoPager(assets: assets, library: library, index: $index, enabled: !busy).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                        Divider()
                        information.frame(width: 280)
                    }
                } else {
                    VStack(spacing: 0) {
                        LocalPhotoPager(assets: assets, library: library, index: $index, enabled: !busy).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "照片")
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 6) {
                            Text("\(current.pixelWidth) × \(current.pixelHeight)")
                            Text("·")
                            LocalPhotoFileSizeLabel(asset: current, loader: fileSize)
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !AppPlatform.isMac { photoActions(current) }
                }
                HStack {
                    Button { if index > 0 { index -= 1 } } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("上一张").disabled(index == 0 || busy)
                        .keyboardShortcut(.leftArrow, modifiers: []).accessibilityIdentifier("previousPhoto")
                    Spacer()
                    Text("\(index + 1) / \(assets.count)").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).accessibilityIdentifier("photoPosition")
                    Spacer()
                    Button { if index + 1 < assets.count { index += 1 } } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }.accessibilityLabel("下一张").disabled(index == assets.count - 1 || busy)
                        .keyboardShortcut(.rightArrow, modifiers: []).accessibilityIdentifier("nextPhoto")
                }.buttonStyle(.plain)
                if AppPlatform.isMac {
                    Divider()
                    photoActions(current)
                    Spacer(minLength: 0)
                }
            }.padding(AppPlatform.isMac ? 20 : 14).background(NASStyle.surface)
        }
    }
    private func photoActions(_ current: PHAsset) -> some View {
        HStack(spacing: 8) {
            Button { busy = true; Task { await library.favorite([current], value: !current.isFavorite); busy = false } } label: {
                Image(systemName: current.isFavorite ? "heart.fill" : "heart").frame(width: 44, height: 44)
            }.accessibilityLabel("收藏照片")
            Button(role: .destructive) { showDelete = true } label: {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }.accessibilityLabel("删除照片")
        }.font(.body).buttonStyle(.plain).disabled(busy)
    }
}
