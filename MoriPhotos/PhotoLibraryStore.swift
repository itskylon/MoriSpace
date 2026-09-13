import SwiftUI
import Photos
import PhotosUI

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PHAsset] = []
    @Published var error: String?
    let manager = PHCachingImageManager()
    private var observing = false
    var canRead: Bool { authorization == .authorized || authorization == .limited }

    override init() {
        super.init()
        reload()
    }
    deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.reload() }
    }
    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        reload()
    }
    func reload() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else { assets = []; return }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in photos.append(asset) }
        assets = photos
    }
    func favorite(_ selected: [PHAsset], value: Bool) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in selected { PHAssetChangeRequest(for: asset).isFavorite = value }
            }
            reload()
        } catch { self.error = friendlyError(error) }
    }
    func delete(_ selected: [PHAsset]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(selected as NSArray) }
            reload()
            return true
        } catch { self.error = friendlyError(error); return false }
    }
    func save(file: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "请在系统设置中允许森空间添加照片。"])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: file, options: nil)
        }
    }
}

struct AssetImage: View {
    let asset: PHAsset
    var large = false
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var failed = false
    @State private var generation = UUID()
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.10)
            if let image {
                if large { ZoomableImage(image: image, onZoomChanged: onZoomChanged, onPrevious: onPrevious, onNext: onNext) }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else if failed {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
            } else { ProgressView().tint(Theme.accent) }
        }
        .clipped()
        .onAppear(perform: load)
        .onDisappear {
            generation = UUID()
            if let requestID { library.manager.cancelImageRequest(requestID) }
            requestID = nil
        }
    }
    private func load() {
        let ticket = UUID()
        generation = ticket
        failed = false
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = library.manager.requestImage(for: asset, targetSize: CGSize(width: large ? 2400 : 450, height: large ? 2400 : 450), contentMode: large ? .aspectFit : .aspectFill, options: options) { result, info in
            Task { @MainActor in
                guard generation == ticket else { return }
                if let result { image = result }
                if info?[PHImageErrorKey] != nil { failed = true }
            }
        }
    }
}

struct LimitedPicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { LimitedPickerController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    private final class LimitedPickerController: UIViewController {
        private var shown = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !shown else { return }
            shown = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
        }
    }
}
