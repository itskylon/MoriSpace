import SwiftUI
import AVKit

private actor VideoAudioSession {
    static let shared = VideoAudioSession()
    private var owners = Set<UUID>()
    func activate(_ owner: UUID) throws {
        if owners.isEmpty {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        }
        owners.insert(owner)
    }
    func release(_ owner: UUID) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct VideoSelection: Identifiable {
    let id = UUID()
    let file: NASFile
    let owner: String
    var localURL: URL? = nil
}

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published var preparing = false
    @Published var buffering = false
    @Published var playing = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var error: String?
    @Published var resumedFrom: Double?
    @Published var progressError: String?
    private let progressStore: VideoProgressStore
    private var progressKey: String?
    private var canSaveProgress = false
    private var lastSavedPosition = 0.0
    private var loader: VideoResourceLoader?
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var generation = UUID()
    private var audioOwner: UUID?

    init(progressStore: VideoProgressStore? = nil) { self.progressStore = progressStore ?? .shared }

    func open(file: NASFile, owner: String, client: SynologyClient?, localURL: URL?, configuration: URLSessionConfiguration = .ephemeral) async {
        stop(); error = nil; progressError = nil; resumedFrom = nil; elapsed = 0; duration = 0; preparing = true
        let ticket = generation
        defer { if ticket == generation { preparing = false } }
        do {
            guard file.canPlayNatively else { throw VideoPlaybackError.unsupportedFormat }
            let asset: AVURLAsset
            var currentFile = file
            if let localURL { asset = AVURLAsset(url: localURL) }
            else {
                guard let client else { throw FileStationError.api(119) }
                let current = try await client.fileInfo(path: file.path)
                currentFile = current
                let request = try await client.videoRequest(path: file.path)
                try Task.checkCancellation()
                guard ticket == generation else { return }
                let source = VideoByteSource(request: request, filename: current.name, expectedSize: current.size, configuration: configuration)
                let loader = VideoResourceLoader(source: source, filename: current.name)
                loader.onError = { [weak self] error in
                    guard let self, self.generation == ticket else { return }
                    self.error = friendlyError(error); self.player.pause()
                }
                self.loader = loader
                _ = try await source.metadata()
                asset = loader.asset
            }
            guard try await asset.load(.isPlayable) else { throw VideoPlaybackError.unsupportedFormat }
            let seconds = try await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard ticket == generation else { return }
            duration = seconds.isFinite ? max(0, seconds) : 0
            progressKey = VideoProgressStore.key(owner: owner, file: currentFile)
            let owner = UUID(); audioOwner = owner
            try await VideoAudioSession.shared.activate(owner)
            if ticket != generation || Task.isCancelled {
                await VideoAudioSession.shared.release(owner)
                return
            }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 5
            player.allowsExternalPlayback = false
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor in
                    guard let self, ticket == self.generation, failed else { return }
                    if self.error == nil { self.error = VideoPlaybackError.unsupportedFormat.localizedDescription }
                    self.player.pause()
                }
            }
            controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let state = player.timeControlStatus
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    self.buffering = state == .waitingToPlayAtSpecifiedRate
                    self.playing = state != .paused
                    if state == .paused { self.saveProgress() }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    if self.error == nil { self.error = "视频播放中断，请检查网络后重试。" }
                    self.player.pause()
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    self.saveProgress()
                    self.resumedFrom = nil
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, ticket == self.generation, time.seconds.isFinite else { return }
                    self.elapsed = max(0, time.seconds)
                    if abs(self.elapsed - self.lastSavedPosition) >= 5 { self.saveProgress() }
                }
            }
            player.replaceCurrentItem(with: item)
            if let key = progressKey, let position = progressStore.position(for: key, duration: duration) {
                let completed = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard ticket == generation, !Task.isCancelled else { return }
                guard completed else { throw VideoPlaybackError.resumeFailed }
                elapsed = position; resumedFrom = position; lastSavedPosition = position
            } else { lastSavedPosition = 0 }
            canSaveProgress = true
            player.play()
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            if self.error == nil { self.error = friendlyError(error) }
            // A cancelled resume seek can still be retried from the beginning on this asset.
            if (error as? VideoPlaybackError) != .resumeFailed { loader?.stop(); loader = nil }
            player.pause()
        }
    }
    func toggle() {
        if playing { pause() }
        else {
            if duration > 0, elapsed >= duration - 0.25 { restart(); return }
            player.play()
        }
    }
    func pause() { player.pause(); saveProgress() }

    func saveProgress() {
        guard canSaveProgress, let key = progressKey else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        do {
            try progressStore.save(key: key, position: position, duration: duration)
            lastSavedPosition = position; progressError = nil
        } catch { lastSavedPosition = position; progressError = "播放进度未能保存，请检查本机存储空间。" }
    }

    func restart() {
        guard duration > 0, !preparing else { return }
        let ticket = generation
        canSaveProgress = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.canSaveProgress = true
                if completed {
                    self.elapsed = 0; self.resumedFrom = nil; self.error = nil
                    self.saveProgress(); self.player.play()
                }
            }
        }
    }
    func jump(_ seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, player.currentTime().seconds + seconds), max(0, duration - 0.1))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() {
        saveProgress(); canSaveProgress = false; progressKey = nil
        generation = UUID()
        player.pause(); player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        itemObservation = nil; controlObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        loader?.stop(); loader = nil
        preparing = false; buffering = false; playing = false
        if let owner = audioOwner { Task { await VideoAudioSession.shared.release(owner) } }
        audioOwner = nil
    }
}

struct VideoPlaybackView: View {
    let selection: VideoSelection
    var client: SynologyClient? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = VideoPlaybackModel()
    @State private var attempt = UUID()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    NativeVideoPlayer(player: model.player)
                    if model.preparing || model.buffering {
                        ProgressView(model.preparing ? "正在准备视频…" : "正在缓冲…").padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 14) {
                    if let error = model.error {
                        Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("videoError")
                        Button("重试播放") { attempt = UUID() }.buttonStyle(.bordered)
                    } else {
                        HStack(spacing: 38) {
                            Button { model.jump(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("后退15秒").accessibilityIdentifier("videoBack")
                            Button { model.toggle() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(model.playing ? "暂停" : "播放").accessibilityIdentifier("videoToggle")
                            Button { model.jump(15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("前进15秒").accessibilityIdentifier("videoForward")
                        }.font(.title2).disabled(model.preparing || model.duration <= 0)
                        Text("\(time(model.elapsed)) / \(time(model.duration))").font(.caption.monospacedDigit())
                            .accessibilityIdentifier("videoElapsed").accessibilityValue(String(Int(model.elapsed)))
                    }
                    if model.duration > 0 {
                        HStack {
                            if let position = model.resumedFrom {
                                Text("已从 \(time(position)) 继续").foregroundStyle(.secondary).accessibilityIdentifier("videoResumed")
                            }
                            Button("从头播放") { model.restart() }.accessibilityIdentifier("videoRestart")
                                .disabled(model.preparing || model.duration <= 0)
                        }.font(.caption)
                    }
                    if let progressError = model.progressError { Text(progressError).font(.caption).foregroundStyle(.orange) }
                    Text(selection.file.name).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }.padding(20)
            }.background(.black).preferredColorScheme(.dark)
                .navigationTitle(selection.localURL == nil ? "在线播放" : "本地播放").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.stop(); dismiss() }.accessibilityIdentifier("closeVideo") } }
        }
        .tint(.mint)
        .task(id: attempt) {
            var configuration = URLSessionConfiguration.ephemeral
            #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
            if FileStationFixture.enabled { configuration = FileStationFixture.configuration() }
            #endif
            await model.open(file: selection.file, owner: selection.owner, client: client, localURL: selection.localURL, configuration: configuration)
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause() } }
    }
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
