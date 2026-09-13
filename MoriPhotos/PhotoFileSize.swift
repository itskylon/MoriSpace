import SwiftUI
import Photos

enum PhotoFileSize {
    static func text(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let units: [(Int64, String)] = [(1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB"), (1, "B")]
        let unit = units.first { bytes >= $0.0 }!
        return (Double(bytes) / Double(unit.0)).formatted(.number.precision(.fractionLength(0...2))) + " " + unit.1
    }
}

@MainActor
final class PhotoFileSizeLoader: ObservableObject {
    enum State: Equatable {
        case loading, available(Int64), unavailable(needsNetwork: Bool)
    }
    @Published private(set) var state: State = .loading
    private let manager = PHAssetResourceManager.default()
    private let useResourceMetadata: Bool
    private var requestID: PHAssetResourceDataRequestID?
    private var generation = UUID()
    private var cache: [String: Int64] = [:]

    init(useResourceMetadata: Bool = true) { self.useResourceMetadata = useResourceMetadata }
    deinit { if let requestID { manager.cancelDataRequest(requestID) } }

    func load(asset: PHAsset, allowNetwork: Bool = false) {
        cancel()
        state = .loading
        let key = asset.localIdentifier + ":" + String(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        if let bytes = cache[key] { state = .available(bytes); return }
        // Measure the original still image only, excluding Live Photo video and edit data.
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            state = .unavailable(needsNetwork: false); return
        }
        if useResourceMetadata, #available(iOS 27, *), let bytes = resource.dataSize, bytes > 0 {
            remember(Int64(bytes), key: key); return
        }
        let ticket = generation
        let counter = ResourceByteCounter()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        requestID = manager.requestData(for: resource, options: options, dataReceivedHandler: { data in
            counter.add(data.count)
        }, completionHandler: { [weak self] error in
            let bytes = counter.value
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.requestID = nil
                if let error {
                    let ns = error as NSError
                    self.state = .unavailable(needsNetwork: ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.networkAccessRequired.rawValue)
                } else if let bytes { self.remember(bytes, key: key) }
                else { self.state = .unavailable(needsNetwork: false) }
            }
        })
    }

    func cancel() {
        generation = UUID()
        if let requestID { manager.cancelDataRequest(requestID) }
        requestID = nil
    }

    private func remember(_ bytes: Int64, key: String) {
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = bytes
        state = .available(bytes)
    }
}

// Count chunks without retaining or re-encoding the original photo.
private final class ResourceByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private var overflow = false
    func add(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = total.addingReportingOverflow(Int64(count))
        overflow = overflow || result.overflow
        total = result.partialValue
    }
    var value: Int64? {
        lock.lock(); defer { lock.unlock() }
        return !overflow && total > 0 ? total : nil
    }
}

struct LocalPhotoFileSizeLabel: View {
    let asset: PHAsset
    @ObservedObject var loader: PhotoFileSizeLoader
    private var resourceKey: String { asset.localIdentifier + ":" + String(asset.modificationDate?.timeIntervalSince1970 ?? 0) }
    var body: some View {
        HStack(spacing: 4) {
            switch loader.state {
            case .available(let bytes):
                Text((asset.mediaSubtypes.contains(.photoLive) ? "静态原图 " : "原图 ") + (PhotoFileSize.text(bytes) ?? "大小暂不可用"))
                    .accessibilityIdentifier("localPhotoFileSize")
            case .loading:
                Text("正在读取大小…")
            case .unavailable(let needsNetwork):
                if needsNetwork {
                    Button { loader.load(asset: asset, allowNetwork: true) } label: {
                        Label("从 iCloud 读取大小", systemImage: "icloud.and.arrow.down")
                    }.buttonStyle(.plain).accessibilityIdentifier("readCloudPhotoSize")
                } else { Text("大小暂不可用").accessibilityIdentifier("localPhotoSizeUnavailable") }
            }
        }
        .onAppear { loader.load(asset: asset) }
        .onChange(of: resourceKey) { _, _ in loader.load(asset: asset) }
        .onDisappear { loader.cancel() }
    }
}
