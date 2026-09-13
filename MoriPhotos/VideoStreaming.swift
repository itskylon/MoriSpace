import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum VideoPlaybackError: LocalizedError, Equatable {
    case unsupportedFormat, rangeUnsupported, invalidRange, changedFile, resumeFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "这个视频的封装或编码暂不受 系统播放器支持。可下载后用兼容的播放器打开。"
        case .rangeUnsupported: return "NAS 或反向代理没有提供视频分段读取，暂时无法直接播放。请先下载，再从“已下载”播放。"
        case .invalidRange: return "视频分段响应不完整或格式异常，请重试。"
        case .changedFile: return "视频文件已发生变化，请刷新目录后重新打开。"
        case .resumeFailed: return "暂时无法恢复上次播放位置，请重试或从头播放。"
        }
    }
}

extension NASFile {
    var isVideo: Bool { !isdir && ["mp4", "mov", "m4v", "3gp", "3g2", "mkv", "avi", "webm", "ts", "m2ts"].contains((name as NSString).pathExtension.lowercased()) }
    var canPlayNatively: Bool { ["mp4", "mov", "m4v", "3gp", "3g2"].contains((name as NSString).pathExtension.lowercased()) }
}

extension SynologyClient {
    func videoRequest(path: String) throws -> URLRequest {
        try NASFile.validatePath(path)
        var request = try makeRequest(api: "SYNO.FileStation.Download", method: "download", parameters: ["path": [path], "mode": "open"], version: 2)
        // HTTP Range is defined for GET. Keep session credentials in the existing
        // Cookie/token headers, never in the media URL or the player's synthetic URL.
        var form = URLComponents()
        form.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = form.queryItems?.filter { !["_sid", "SynoToken"].contains($0.name) }
        // DSM parses query strings as form data too: preserve literal '+' in filenames.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = url.url else { throw NASError.invalidAddress }
        request.url = endpoint; request.httpMethod = "GET"; request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 30
        return request
    }
}

struct VideoContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
    var count: Int64 { end - start + 1 }
    static func parse(_ header: String?, requestedStart: Int64, requestedEnd: Int64) throws -> Self {
        guard let header, header.hasPrefix("bytes ") else { throw VideoPlaybackError.invalidRange }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw VideoPlaybackError.invalidRange }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(parts[1]),
              start == requestedStart, start >= 0, end >= start, end <= requestedEnd, total > end,
              end == min(requestedEnd, total - 1) else { throw VideoPlaybackError.invalidRange }
        return Self(start: start, end: end, total: total)
    }
}

// A bounded in-memory window; the full video is never accumulated or written to disk.
actor VideoByteSource {
    static let blockSize: Int64 = 512 * 1024
    private let request: URLRequest
    private let session: URLSession
    private let expectedSize: Int64?
    private let contentType: String
    private var total: Int64?
    private var stopped = false
    private var cache: [Int64: Data] = [:]
    private var recent: [Int64] = []
    private(set) var bytesReceived: Int64 = 0
    init(request: URLRequest, filename: String, expectedSize: Int64?, configuration: URLSessionConfiguration = .ephemeral) {
        self.request = request; self.expectedSize = expectedSize
        contentType = UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    func metadata() async throws -> (length: Int64, type: String) {
        guard !stopped else { throw CancellationError() }
        if let total { return (total, contentType) }
        let (_, length) = try await fetch(start: 0, end: 1)
        guard !stopped else { throw CancellationError() }
        total = length
        return (length, contentType)
    }
    func read(offset: Int64, length: Int) async throws -> Data {
        guard !stopped else { throw CancellationError() }
        let info = try await metadata()
        guard offset >= 0, offset <= info.length, length >= 0 else { throw VideoPlaybackError.invalidRange }
        if offset == info.length || length == 0 { return Data() }
        let block = offset / Self.blockSize * Self.blockSize
        let data: Data
        if let cached = cache[block] { data = cached }
        else {
            let (value, count) = try await fetch(start: block, end: min(block + Self.blockSize - 1, info.length - 1))
            guard !stopped else { throw CancellationError() }
            guard count == info.length else { throw VideoPlaybackError.changedFile }
            data = value; cache[block] = data
        }
        recent.removeAll { $0 == block }; recent.append(block)
        while recent.count > 8 { cache[recent.removeFirst()] = nil }
        let start = Int(offset - block)
        let end = start + min(length, data.count - start)
        return data.subdata(in: start..<end)
    }
    func stop() { stopped = true; cache.removeAll(); recent.removeAll(); session.invalidateAndCancel() }
    private func fetch(start: Int64, end: Int64) async throws -> (Data, Int64) {
        try Task.checkCancellation()
        var query = request
        query.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: query)
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler(operation: {
            guard let http = response as? HTTPURLResponse else { throw NASError.invalidResponse }
            if (300..<400).contains(http.statusCode) { throw NASError.redirect }
            if http.mimeType?.lowercased().contains("json") == true {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte); if data.count >= 4096 { break }
                }
                if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponse>.self, from: data), !envelope.success { throw FileStationError.api(envelope.error?.code ?? -1) }
                throw VideoPlaybackError.invalidRange
            }
            if http.statusCode == 200 { throw VideoPlaybackError.rangeUnsupported }
            guard http.statusCode == 206 else { throw NASError.http(http.statusCode) }
            let range = try VideoContentRange.parse(http.value(forHTTPHeaderField: "Content-Range"), requestedStart: start, requestedEnd: end)
            if let expectedSize, expectedSize > 0, expectedSize != range.total { throw VideoPlaybackError.changedFile }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { throw VideoPlaybackError.invalidRange }
            var data = Data(); data.reserveCapacity(Int(range.count))
            for try await byte in bytes {
                if data.count % 8192 == 0 { try Task.checkCancellation() }
                guard data.count < Int(range.count) else { throw VideoPlaybackError.invalidRange }
                data.append(byte)
            }
            guard data.count == Int(range.count) else { throw VideoPlaybackError.invalidRange }
            bytesReceived += Int64(data.count)
            return (data, range.total)
        }, onCancel: { bytes.task.cancel() })
    }
}

// All AVFoundation delegate callbacks and request delivery are serialized on main.
@MainActor
final class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let source: VideoByteSource
    let asset: AVURLAsset
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    var onError: ((Error) -> Void)?
    init(source: VideoByteSource, filename: String) {
        self.source = source
        let ext = (filename as NSString).pathExtension
        asset = AVURLAsset(url: URL(string: "mori-video://\(UUID().uuidString)/video.\(ext)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { start(request) }
        return true
    }
    private func start(_ request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                let info = try await source.metadata()
                try Task.checkCancellation()
                if let content = request.contentInformationRequest {
                    content.contentType = info.type
                    content.contentLength = info.length
                    content.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    var offset = max(data.requestedOffset, data.currentOffset)
                    let requestedLength = Int64(data.requestedLength)
                    let remaining = max(0, info.length - data.requestedOffset)
                    let end = data.requestsAllDataToEndOfResource ? info.length : data.requestedOffset + min(requestedLength, remaining)
                    while offset < end {
                        try Task.checkCancellation()
                        let chunk = try await source.read(offset: offset, length: Int(min(end - offset, VideoByteSource.blockSize)))
                        try Task.checkCancellation()
                        guard !request.isCancelled, !chunk.isEmpty else { throw CancellationError() }
                        data.respond(with: chunk)
                        offset += Int64(chunk.count)
                    }
                }
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !Task.isCancelled && !request.isCancelled {
                    onError?(error); request.finishLoading(with: error)
                }
            }
        }
    }
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    }
    func stop() {
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        asset.cancelLoading()
        Task { await source.stop() }
    }
}
