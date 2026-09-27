import Foundation
import Darwin

enum UsageWidgetConstants {
    static let kind = "MoriUsageWidget"
    static let maximumAge: TimeInterval = 15 * 60
    static let maximumFileSize = 1_048_576
    static let fileName = "usage-widget-v1.json"
}

enum UsageWidgetError: Error, LocalizedError {
    case invalidData, unsupportedVersion, futureSnapshot, oversizedFile, unavailableContainer
    var errorDescription: String? {
        switch self {
        case .invalidData: return "额度数据格式不正确。"
        case .unsupportedVersion: return "额度文件版本暂不支持，请更新森空间。"
        case .futureSnapshot: return "额度采集时间晚于当前时间，请检查设备时钟。"
        case .oversizedFile: return "额度文件过大。"
        case .unavailableContainer: return "无法访问小组件共享目录。"
        }
    }
}

struct UsageWidgetWindow: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }

    static func periodLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}

struct UsageWidgetSnapshot: Codable, Equatable {
    enum Status: String, Codable { case ready, notConnected, unavailable }
    var version = 1
    let fetchedAt: Date
    let validUntil: Date
    let status: Status
    let windows: [UsageWidgetWindow]

    static func empty(_ status: Status, now: Date = Date()) -> Self {
        Self(fetchedAt: now, validUntil: now.addingTimeInterval(UsageWidgetConstants.maximumAge), status: status, windows: [])
    }

    func validated(now: Date = Date()) throws -> Self {
        guard version == 1 else { throw UsageWidgetError.unsupportedVersion }
        guard Self.validDate(fetchedAt), Self.validDate(validUntil), validUntil >= fetchedAt,
              validUntil.timeIntervalSince(fetchedAt) <= UsageWidgetConstants.maximumAge,
              windows.count <= 64, Set(windows.map(\.id)).count == windows.count else { throw UsageWidgetError.invalidData }
        guard fetchedAt <= now else { throw UsageWidgetError.futureSnapshot }
        guard status == .ready || windows.isEmpty else { throw UsageWidgetError.invalidData }
        for window in windows {
            guard !window.id.isEmpty, window.id.count <= 160,
                  !window.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, window.label.count <= 120,
                  !window.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !window.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UsageWidgetError.invalidData }
            if let percent = window.usedPercent, !percent.isFinite || !(0...100).contains(percent) { throw UsageWidgetError.invalidData }
            if let minutes = window.windowMinutes, minutes <= 0 { throw UsageWidgetError.invalidData }
            if let reset = window.resetsAt, !Self.validDate(reset) { throw UsageWidgetError.invalidData }
        }
        return self
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds > 0 && seconds <= 253_402_300_799
    }

    func encoded(now: Date = Date()) throws -> Data {
        _ = try validated(now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= UsageWidgetConstants.maximumFileSize else { throw UsageWidgetError.oversizedFile }
        return data
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= UsageWidgetConstants.maximumFileSize else { throw UsageWidgetError.oversizedFile }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Self.self, from: data).validated(now: now)
    }

    /// Accepts the official account/rateLimits/read result or its JSON-RPC envelope.
    /// Only the allowlisted quota fields are retained; account and credential fields are ignored.
    static func parseRateLimits(_ data: Data, fetchedAt: Date = Date(), now: Date = Date()) throws -> Self {
        guard data.count <= UsageWidgetConstants.maximumFileSize else { throw UsageWidgetError.oversizedFile }
        let payload = try JSONDecoder().decode(UsageRateLimitsDocument.self, from: data).payload
        let buckets: [(String, UsageRateLimitsBucket)]
        if let multiple = payload.rateLimitsByLimitId, !multiple.isEmpty {
            buckets = multiple.keys.sorted { lhs, rhs in
                if lhs == "codex" { return rhs != "codex" }
                if rhs == "codex" { return false }
                return lhs < rhs
            }.compactMap { key in multiple[key].flatMap { $0 }.map { (key, $0) } }
        } else if let single = payload.rateLimits {
            buckets = [(single.limitId ?? "codex", single)]
        } else { buckets = [] }
        var windows: [UsageWidgetWindow] = []
        for (id, bucket) in buckets {
            guard !id.isEmpty, id.count <= 128 else { throw UsageWidgetError.invalidData }
            let rawName = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? (id == "codex" ? "Codex" : id)
            let displayName = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(60))
            for (position, fallback, window) in [("primary", "主额度", bucket.primary), ("secondary", "次额度", bucket.secondary)] {
                guard let window else { continue }
                let period = UsageWidgetWindow.periodLabel(minutes: window.windowDurationMins, fallback: fallback)
                windows.append(UsageWidgetWindow(id: id + ":" + position, label: displayName + " · " + period,
                    usedPercent: window.usedPercent, windowMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }))
            }
        }
        return try Self(fetchedAt: fetchedAt, validUntil: fetchedAt.addingTimeInterval(UsageWidgetConstants.maximumAge),
                        status: .ready, windows: windows).validated(now: now)
    }

    var expiresAt: Date { min(validUntil, fetchedAt.addingTimeInterval(UsageWidgetConstants.maximumAge)) }
    func isStale(at date: Date) -> Bool { date < fetchedAt || date >= expiresAt }
    func requiresRefresh(for window: UsageWidgetWindow, at date: Date) -> Bool {
        isStale(at: date) || window.resetsAt.map { date >= $0 } == true
    }
    func timelineDates(now: Date) -> [Date] {
        var dates = Set([now])
        guard status == .ready else { return [now] }
        if expiresAt > now { dates.insert(expiresAt) }
        for window in windows {
            if let reset = window.resetsAt, reset > now, reset <= expiresAt { dates.insert(reset) }
        }
        return dates.sorted()
    }
    func nextReloadDate(now: Date) -> Date {
        timelineDates(now: now).first(where: { $0 > now }) ?? now.addingTimeInterval(UsageWidgetConstants.maximumAge)
    }
}

private struct UsageRateLimitsDocument: Decodable {
    let payload: UsageRateLimitsPayload
    private enum CodingKeys: String, CodingKey { case result, error }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.error), try !container.decodeNil(forKey: .error) { throw UsageWidgetError.invalidData }
        if container.contains(.result) { payload = try container.decode(UsageRateLimitsPayload.self, forKey: .result) }
        else { payload = try UsageRateLimitsPayload(from: decoder) }
    }
}
private struct UsageRateLimitsPayload: Decodable {
    let rateLimits: UsageRateLimitsBucket?
    let rateLimitsByLimitId: [String: UsageRateLimitsBucket?]?
    private enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.rateLimits) || container.contains(.rateLimitsByLimitId) else { throw UsageWidgetError.invalidData }
        rateLimitsByLimitId = try container.decodeIfPresent([String: UsageRateLimitsBucket?].self, forKey: .rateLimitsByLimitId)
        if let multiple = rateLimitsByLimitId, !multiple.isEmpty { rateLimits = nil }
        else { rateLimits = try container.decodeIfPresent(UsageRateLimitsBucket.self, forKey: .rateLimits) }
    }
}
private struct UsageRateLimitsBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: UsageRateLimitsWindow?
    let secondary: UsageRateLimitsWindow?
}
private struct UsageRateLimitsWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

struct UsageWidgetCache {
    let fileURL: URL?
    init(fileURL: URL?) { self.fileURL = fileURL }
    static var shared: Self {
        let group = Bundle.main.object(forInfoDictionaryKey: "MoriCalendarAppGroup") as? String
        let folder = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        return Self(fileURL: folder?.appendingPathComponent(UsageWidgetConstants.fileName))
    }
    func read(now: Date = Date()) -> UsageWidgetSnapshot {
        guard let fileURL else { return .empty(.unavailable, now: now) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty(.notConnected, now: now) }
        // Query the filesystem on every read, including the link itself, not cached URL metadata.
        do { return try readValidated(now: now) }
        catch { return .empty(.unavailable, now: now) }
    }
    @discardableResult
    func write(_ snapshot: UsageWidgetSnapshot, now: Date = Date()) throws -> UsageWidgetSnapshot {
        guard let fileURL else { throw UsageWidgetError.unavailableContainer }
        let data = try snapshot.encoded(now: now)
        // The app and native Mac widget are separate processes. Keep comparison and
        // atomic replacement under the same lock so a late response cannot roll back either writer.
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(descriptor, LOCK_UN) }
        if let existing = try? readValidated(now: now), existing.fetchedAt > snapshot.fetchedAt { return existing }
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
        return snapshot
    }

    func remove() throws {
        guard let fileURL else { throw UsageWidgetError.unavailableContainer }
        let descriptor = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(descriptor, LOCK_UN) }
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    private func readValidated(now: Date) throws -> UsageWidgetSnapshot {
        guard let fileURL else { throw UsageWidgetError.unavailableContainer }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= Int64(UsageWidgetConstants.maximumFileSize) else { throw UsageWidgetError.oversizedFile }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: UsageWidgetConstants.maximumFileSize + 1) ?? Data()
        return try UsageWidgetSnapshot.decode(data, now: now)
    }

}

enum UsageWidgetRoute {
    static let url = URL(string: "morispace://usage")!
    static func matchesConnection(_ url: URL) -> Bool {
        guard url == URL(string: "morispace://usage/connect") else { return false }
        return true
    }
    static func matches(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "morispace" && parts.host == "usage" && parts.user == nil && parts.password == nil
            && parts.port == nil && parts.path.isEmpty && parts.query == nil && parts.fragment == nil
    }
}
