import Foundation
import CryptoKit

/// Stores only hashed file identities and playback times, never NAS credentials or paths.
@MainActor
final class VideoProgressStore {
    static let shared: VideoProgressStore = {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoPlayback", isDirectory: true)
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        if FileStationFixture.enabled {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPlaybackQA", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-video-progress") { try? FileManager.default.removeItem(at: directory) }
        }
        #endif
        return VideoProgressStore(directory: directory)
    }()

    private struct Entry: Codable {
        let position: Double
        let duration: Double
        let updated: Date
    }
    private let directory: URL
    private var manifest: URL { directory.appendingPathComponent("progress.json") }
    private var entries: [String: Entry] = [:]

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: manifest), let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    static func key(owner: String, file: NASFile) -> String {
        // Modification metadata prevents resuming a replacement file at an old position.
        let parts = [owner, file.path, file.size.map { String($0) } ?? "", file.additional?.time?.mtime.map { String($0) } ?? ""]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isFinished(position: Double, duration: Double) -> Bool {
        duration > 0 && position >= duration - min(5, duration * 0.02)
    }

    func position(for key: String, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, let entry = entries[key],
              entry.position.isFinite, entry.duration.isFinite, entry.position >= 2,
              abs(entry.duration - duration) <= max(1, duration * 0.001),
              !Self.isFinished(position: entry.position, duration: duration) else { return nil }
        return entry.position
    }

    func save(key: String, position: Double, duration: Double) throws {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        if position < 2 || Self.isFinished(position: position, duration: duration) {
            try remove(key: key)
            return
        }
        let previous = entries
        entries[key] = Entry(position: position, duration: duration, updated: Date())
        if entries.count > 500 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.updated > $1.value.updated }.prefix(500).map { ($0.key, $0.value) })
        }
        do { try persist() } catch { entries = previous; throw error }
    }

    func remove(key: String) throws {
        guard entries[key] != nil else { return }
        let previous = entries
        entries.removeValue(forKey: key)
        do { try persist() } catch { entries = previous; throw error }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: manifest, options: [.atomic, .completeFileProtection])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}
