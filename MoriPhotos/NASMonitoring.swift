import Foundation
import Combine

// Decode only data needed by the dashboard. Missing or invalid values stay unknown.
indirect enum MonitorValue: Decodable {
    case object([String: MonitorValue]), array([MonitorValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: MonitorValue].self) { self = .object(v) }
        else { self = .array(try c.decode([MonitorValue].self)) }
    }
    subscript(_ key: String) -> MonitorValue { if case .object(let value) = self { return value[key] ?? .null }; return .null }
    var values: [MonitorValue]? { if case .array(let value) = self { return value }; return nil }
    var text: String? { if case .string(let value) = self, !value.isEmpty { return value }; return nil }
    var number: Double? {
        let value: Double?
        switch self { case .number(let v): value = v; case .string(let v): value = Double(v); default: value = nil }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    var nonnegative: Double? { number.flatMap { $0 >= 0 ? $0 : nil } }
    var percent: Double? { number.flatMap { (0...100).contains($0) ? $0 : nil } }
    var temperature: Double? { number.flatMap { (1...150).contains($0) ? $0 : nil } }
    var flag: Bool? {
        if case .bool(let value) = self { return value }
        if let value = number, value == 0 || value == 1 { return value == 1 }
        if let value = text { return ["yes", "true"].contains(value) ? true : (["no", "false"].contains(value) ? false : nil) }
        return nil
    }
}

struct NASSystemStatus: Decodable {
    let model: String?
    let version: String?
    let temperature: Double?
    let temperatureWarning: Bool?
    let uptime: TimeInterval?
    init(from decoder: Decoder) throws {
        let v = try MonitorValue(from: decoder)
        model = v["model"].text
        version = v["firmware_ver"].text ?? v["version_string"].text
        temperature = v["sys_temp"].temperature
        let flags = [v["sys_tempwarn"].flag, v["systempwarn"].flag, v["temperature_warning"].flag].compactMap { $0 }
        temperatureWarning = flags.isEmpty ? nil : flags.contains(true)
        uptime = Self.parseUptime(v["up_time"].text) ?? v["uptime"].nonnegative
        guard model != nil || temperature != nil || uptime != nil else { throw NASError.invalidResponse }
    }
    static func parseUptime(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }), parts[1] < 60, parts[2] < 60 else { return nil }
        let seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return seconds.isFinite ? seconds : nil
    }
}

struct NASResourceStatus: Decodable {
    let cpu: Double?
    let memory: Double?
    let memoryBytes: Double?
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
    init(from decoder: Decoder) throws {
        let v = try MonitorValue(from: decoder)
        let loads = [v["cpu"]["user_load"].percent, v["cpu"]["system_load"].percent, v["cpu"]["other_load"].percent].compactMap { $0 }
        let total = loads.reduce(0, +)
        cpu = loads.count == 3 && total <= 100 ? total : nil
        memory = v["memory"]["real_usage"].percent
        // DSM reports memory in KiB; network rates and volume sizes are already bytes.
        memoryBytes = v["memory"]["memory_size"].nonnegative.flatMap { $0 > 0 && $0 < 1e15 ? $0 * 1024 : nil }
        let network = v["network"].values?.first { $0["device"].text == "total" }
        receivedBytesPerSecond = network?["rx"].nonnegative
        sentBytesPerSecond = network?["tx"].nonnegative
        guard cpu != nil || memory != nil || receivedBytesPerSecond != nil || sentBytesPerSecond != nil else { throw NASError.invalidResponse }
    }
}

enum NASHealth: Int {
    case normal, unknown, warning, critical
    init(_ value: String?) {
        switch value?.lowercased() {
        case "normal", "healthy": self = .normal
        case "warning", "degraded", "repairing", "rebuilding", "not_initialized", "not_verified", "initialized": self = .warning
        case "critical", "crashed", "failing", "failed", "error": self = .critical
        default: self = .unknown
        }
    }
    var title: String {
        switch self { case .normal: return "正常"; case .warning: return "需关注"; case .critical: return "异常"; case .unknown: return "未知" }
    }
}

struct NASVolumeStatus: Identifiable {
    let id: String
    let total: Double?
    let used: Double?
    let health: NASHealth
    let rawStatus: String?
    var fraction: Double? { guard let used, let total, total > 0, used <= total else { return nil }; return used / total }
    var lowSpace: Bool { (fraction ?? 0) >= 0.9 }
    init(_ v: MonitorValue, index: Int) {
        id = v["id"].text ?? "volume_\(index + 1)"
        total = v["size"]["total"].nonnegative.flatMap { $0 > 0 ? $0 : nil }
        used = v["size"]["used"].nonnegative
        rawStatus = v["status"].text
        health = NASHealth(rawStatus)
    }
}

struct NASDiskStatus: Identifiable {
    let id: String
    let name: String
    let temperature: Double?
    let health: NASHealth
    let rawStatus: String?
    init(_ v: MonitorValue, index: Int) {
        id = v["id"].text ?? "disk_\(index + 1)"
        name = v["name"].text ?? v["display_name"].text ?? "硬盘 \(index + 1)"
        temperature = v["temp"].temperature
        let statuses = [v["overview_status"].text, v["status"].text, v["smart_status"].text].compactMap { $0 }
        let worst = statuses.max { NASHealth($0).rawValue < NASHealth($1).rawValue }
        rawStatus = worst; health = NASHealth(worst)
    }
}

struct NASStorageStatus: Decodable {
    let volumes: [NASVolumeStatus]
    let disks: [NASDiskStatus]
    let volumesReported: Bool
    let disksReported: Bool
    init(from decoder: Decoder) throws {
        let v = try MonitorValue(from: decoder)
        volumesReported = v["volumes"].values != nil; disksReported = v["disks"].values != nil
        volumes = (v["volumes"].values ?? []).enumerated().map { NASVolumeStatus($0.element, index: $0.offset) }
        disks = (v["disks"].values ?? []).enumerated().map { NASDiskStatus($0.element, index: $0.offset) }
        guard volumesReported || disksReported else { throw NASError.invalidResponse }
    }
}

struct NASMonitorIssue: Identifiable {
    let section: String
    let message: String
    let retryable: Bool
    var id: String { section }
    init(section: String, error: Error) {
        self.section = section
        if case NASError.api(let code) = error, [105, 403].contains(code) {
            message = "当前账号没有读取\(section)的权限（\(code)）。请在 DSM 检查账号的系统监控权限。"; retryable = false
        } else if case NASError.unsupported = error {
            message = "NAS 未提供兼容的\(section)接口。"; retryable = false
        } else {
            message = friendlyError(error)
            retryable = !isExpiredNASSession(error) && !needsManualNASLogin(error)
        }
    }
}

struct NASMonitorSnapshot {
    var system: NASSystemStatus?
    var resources: NASResourceStatus?
    var storage: NASStorageStatus?
    var issues: [NASMonitorIssue] = []
    var updatedAt = Date()
    var hasData: Bool { system != nil || resources != nil || storage != nil }
    var hasAttention: Bool {
        system?.temperatureWarning == true || storage?.volumes.contains(where: { $0.health == .warning || $0.health == .critical || $0.lowSpace }) == true || storage?.disks.contains(where: { $0.health == .warning || $0.health == .critical }) == true
    }
}

extension SynologyClient {
    private func monitorRead<T: Decodable>(_ type: T.Type, api: String, method: String, maximum: Int = 1) async -> Result<T, Error> {
        do {
            try Task.checkCancellation()
            let version = try supportedVersion(api: api, maximum: maximum)
            return .success(try await call(api: api, method: method, parameters: [:], version: version))
        } catch { return .failure(error) }
    }
    func monitorSnapshot() async -> NASMonitorSnapshot {
        async let system = monitorRead(NASSystemStatus.self, api: "SYNO.Core.System", method: "info", maximum: 3)
        async let resources = monitorRead(NASResourceStatus.self, api: "SYNO.Core.System.Utilization", method: "get")
        async let storage = monitorRead(NASStorageStatus.self, api: "SYNO.Storage.CGI.Storage", method: "load_info")
        var snapshot = NASMonitorSnapshot()
        switch await system { case .success(let v): snapshot.system = v; case .failure(let e): snapshot.issues.append(.init(section: "系统信息", error: e)) }
        switch await resources { case .success(let v): snapshot.resources = v; case .failure(let e): snapshot.issues.append(.init(section: "实时负载", error: e)) }
        switch await storage { case .success(let v): snapshot.storage = v; case .failure(let e): snapshot.issues.append(.init(section: "存储状态", error: e)) }
        snapshot.updatedAt = Date()
        return snapshot
    }
}

struct NASLoadSample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
}

@MainActor
final class NASMonitorStore: ObservableObject {
    @Published private(set) var snapshot: NASMonitorSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var samples: [NASLoadSample] = []
    @Published private(set) var halted = false
    private var generation = UUID()
    private var request: Task<NASMonitorSnapshot, Never>?
    private var polling: Task<Void, Never>?

    func start(client: SynologyClient, automatic: Bool) {
        stop()
        polling = Task { [weak self] in
            guard let self else { return }
            if automatic { await self.run(client: client) }
            else if self.snapshot == nil { await self.refresh(client: client) }
        }
    }

    func refresh(client: SynologyClient) async {
        guard !loading else { return }
        let ticket = generation
        loading = true
        let pending = Task { await client.monitorSnapshot() }
        request = pending
        let result = await withTaskCancellationHandler(operation: { await pending.value }, onCancel: { pending.cancel() })
        guard generation == ticket else { return }
        request = nil; loading = false
        guard !Task.isCancelled, !pending.isCancelled else { return }
        snapshot = result
        // Stop automatic polling for a permanent failure if nothing can be displayed.
        halted = !result.hasData && !result.issues.isEmpty && result.issues.allSatisfy { !$0.retryable }
        if let r = result.resources {
            samples.append(NASLoadSample(date: result.updatedAt, cpu: r.cpu, memory: r.memory))
            samples = Array(samples.suffix(40))
        }
    }
    func run(client: SynologyClient, interval: Duration = .seconds(15)) async {
        let ticket = generation
        while !Task.isCancelled && ticket == generation {
            await refresh(client: client)
            if halted || Task.isCancelled || ticket != generation { return }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
    func stop() {
        generation = UUID(); polling?.cancel(); polling = nil; request?.cancel(); request = nil; loading = false
    }
}

enum NASMonitorFormat {
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
    static func uptime(_ value: TimeInterval?) -> String {
        guard let value, value >= 0, value < 1e10 else { return "—" }
        let hours = Int(value / 3600), minutes = Int(value / 60) % 60
        return hours >= 24 ? "\(hours / 24) 天 \(hours % 24) 小时" : "\(hours) 小时 \(minutes) 分"
    }
}
