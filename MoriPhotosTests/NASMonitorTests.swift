#if targetEnvironment(simulator)
import XCTest
@testable import MoriPhotos

// Each URLSession has its own handler. Canceled requests from an earlier test
// must not be routed to the next test's server.
private final class MonitorTestProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]
    static func register(host: String, handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.cancelled) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class NASMonitorTests: XCTestCase {
    private var responder: ((URLRequest) throws -> (Int, Data))?
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    override func tearDown() { responder = nil; super.tearDown() }

    func testSystemUsesHoursMinutesSecondsAndRejectsInvalidSensors() throws {
        let system = try decode(NASSystemStatus.self, ["model": "DS-test", "up_time": "75:12:09", "sys_temp": "42", "sys_tempwarn": false])
        XCTAssertEqual(system.uptime, 270729)
        XCTAssertEqual(system.temperature, 42)
        XCTAssertEqual(NASMonitorFormat.uptime(system.uptime), "3 天 3 小时")
        for value in ["", "1:60:00", "1:00:60", "1:x:02", "nan:2:3", "-1:2:3"] { XCTAssertNil(NASSystemStatus.parseUptime(value)) }
        let unknown = try decode(NASSystemStatus.self, ["model": "DS-test", "sys_temp": -1])
        XCTAssertNil(unknown.temperature); XCTAssertNil(unknown.temperatureWarning); XCTAssertNil(unknown.uptime)
        XCTAssertEqual(NASMonitorFormat.percent(nil), "—")
        XCTAssertEqual(NASMonitorFormat.bytes(.infinity), "—")
    }

    func testResourceUnitsAndTotalInterfaceAreNotDoubleCounted() throws {
        let resource = try decode(NASResourceStatus.self, [
            "cpu": ["user_load": "12", "system_load": 4, "other_load": 2],
            "memory": ["real_usage": "36", "memory_size": "8388608"],
            "network": [["device": "total", "rx": 1024, "tx": 2048], ["device": "eth0", "rx": 1024, "tx": 2048]]
        ])
        XCTAssertEqual(resource.cpu, 18); XCTAssertEqual(resource.memory, 36)
        XCTAssertEqual(resource.memoryBytes, 8_589_934_592)
        XCTAssertEqual(resource.receivedBytesPerSecond, 1024); XCTAssertEqual(resource.sentBytesPerSecond, 2048)
        let missing = try decode(NASResourceStatus.self, ["cpu": ["user_load": 10], "memory": ["real_usage": 0], "network": [["device": "eth0", "rx": 999]]])
        XCTAssertNil(missing.cpu); XCTAssertEqual(missing.memory, 0); XCTAssertNil(missing.sentBytesPerSecond); XCTAssertNil(missing.receivedBytesPerSecond)
    }

    func testInvalidResponsesDoNotMasqueradeAsIdleHealthyNAS() throws {
        XCTAssertThrowsError(try decode(NASResourceStatus.self, [:]))
        XCTAssertThrowsError(try decode(NASResourceStatus.self, ["cpu": ["user_load": 90, "system_load": 90, "other_load": 0], "memory": ["real_usage": 110]]))
        XCTAssertThrowsError(try decode(NASSystemStatus.self, [:]))
        XCTAssertThrowsError(try decode(NASStorageStatus.self, [:]))
        let empty = try decode(NASStorageStatus.self, ["volumes": []])
        XCTAssertTrue(empty.volumesReported); XCTAssertFalse(empty.disksReported)
    }

    func testStorageNumericStringsCapacityWarningsAndWorstDiskHealth() throws {
        let storage = try decode(NASStorageStatus.self, [
            "volumes": [["id": "volume_1", "status": "normal", "size": ["total": "1000", "used": "950"]], ["id": "volume_2", "status": "new_status", "size": ["total": "0", "used": "1"]]],
            "disks": [["id": "disk1", "status": "normal", "overview_status": "normal", "smart_status": "failing", "temp": "39"], ["id": "disk2", "temp": -1]]
        ])
        XCTAssertEqual(storage.volumes[0].fraction, 0.95); XCTAssertTrue(storage.volumes[0].lowSpace)
        XCTAssertNil(storage.volumes[1].fraction); XCTAssertEqual(storage.volumes[1].health, .unknown)
        XCTAssertEqual(storage.disks[0].health, .critical); XCTAssertEqual(storage.disks[0].temperature, 39)
        XCTAssertEqual(storage.disks[1].health, .unknown); XCTAssertNil(storage.disks[1].temperature)
        XCTAssertTrue(NASMonitorSnapshot(storage: storage).hasAttention)
    }

    private func client() async throws -> SynologyClient {
        let host = "monitor-" + UUID().uuidString.lowercased() + ".invalid"
        MonitorTestProtocol.register(host: host, handler: try XCTUnwrap(responder))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MonitorTestProtocol.self]
        let client = try SynologyClient(address: "https://" + host + "/photo", service: .monitor, session: URLSession(configuration: config))
        try await client.resume(NASSession(sid: "test-session", token: "test-token"))
        return client
    }

    func testReadOnlyRequestsAndPartialPermissionFailure() async throws {
        responder = { request in
            let fields = FileStationFixture.fields(request), api = fields["api"] ?? ""
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "POST")
            if api == "SYNO.API.Info" {
                // Discovery always uses query.cgi.
                XCTAssertEqual(request.url?.path, "/webapi/query.cgi")
                return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": NASMonitorFixture.info]))
            }
            XCTAssertEqual(request.url?.path, "/webapi/entry.cgi")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=test-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "test-token")
            let methods = ["SYNO.Core.System": "info", "SYNO.Core.System.Utilization": "get", "SYNO.Storage.CGI.Storage": "load_info"]
            XCTAssertEqual(fields["method"], methods[api])
            XCTAssertEqual(fields["version"], api == "SYNO.Core.System" ? "3" : "1")
            let result: [String: Any] = api == "SYNO.Storage.CGI.Storage" ? ["success": false, "error": ["code": 105]] : ["success": true, "data": NASMonitorFixture.response(api: api)!]
            return (200, try JSONSerialization.data(withJSONObject: result))
        }
        let client = try await client()
        let snapshot = await client.monitorSnapshot()
        XCTAssertNotNil(snapshot.system); XCTAssertEqual(snapshot.resources?.cpu, 18); XCTAssertNil(snapshot.storage)
        XCTAssertEqual(snapshot.issues.count, 1); XCTAssertTrue(snapshot.issues[0].message.contains("权限")); XCTAssertFalse(snapshot.issues[0].retryable)
        await client.close()
    }

    @MainActor
    func testPermanentFailuresStopAutomaticPollingWithoutInventingData() async throws {
        let lock = NSLock()
        var reads = 0
        responder = { request in
            let api = FileStationFixture.fields(request)["api"] ?? ""
            if api == "SYNO.API.Info" { return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": NASMonitorFixture.info])) }
            lock.lock(); reads += 1; lock.unlock()
            return (200, try JSONSerialization.data(withJSONObject: ["success": false, "error": ["code": 105]]))
        }
        let client = try await client(), store = NASMonitorStore()
        await store.run(client: client, interval: .milliseconds(10))
        XCTAssertTrue(store.halted); XCTAssertFalse(store.snapshot?.hasData ?? true)
        XCTAssertTrue(store.samples.isEmpty); XCTAssertEqual(reads, 3)
        await client.close()
    }

    func testVersionDiscoveryAndMissingAPIKeepOtherSectionsAvailable() async throws {
        responder = { request in
            let fields = FileStationFixture.fields(request), api = fields["api"] ?? ""
            if api == "SYNO.API.Info" {
                var info = NASMonitorFixture.info
                info.removeValue(forKey: "SYNO.Core.System.Utilization")
                info["SYNO.Core.System"]?["maxVersion"] = 1
                return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": info]))
            }
            XCTAssertNotEqual(api, "SYNO.Core.System.Utilization")
            XCTAssertEqual(fields["version"], "1")
            return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": NASMonitorFixture.response(api: api)!]))
        }
        let client = try await client()
        let snapshot = await client.monitorSnapshot()
        XCTAssertNotNil(snapshot.system); XCTAssertNotNil(snapshot.storage); XCTAssertNil(snapshot.resources)
        XCTAssertEqual(snapshot.issues.count, 1); XCTAssertTrue(snapshot.issues[0].message.contains("接口"))
        await client.close()
    }

    @MainActor
    func testLeavingCancelsInFlightRefreshAndDoesNotPublishLateData() async throws {
        let started = expectation(description: "request started"); started.assertForOverFulfill = false
        responder = { request in
            let api = FileStationFixture.fields(request)["api"] ?? ""
            if api == "SYNO.API.Info" { return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": NASMonitorFixture.info])) }
            started.fulfill(); Thread.sleep(forTimeInterval: 0.15)
            return (200, try JSONSerialization.data(withJSONObject: ["success": true, "data": NASMonitorFixture.response(api: api)!]))
        }
        let client = try await client(), store = NASMonitorStore()
        let refresh = Task { await store.refresh(client: client) }
        await fulfillment(of: [started], timeout: 3)
        store.stop()
        await refresh.value
        XCTAssertNil(store.snapshot); XCTAssertFalse(store.loading); XCTAssertTrue(store.samples.isEmpty)
        await client.close()
    }
}
#endif
