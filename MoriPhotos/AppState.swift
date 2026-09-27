import SwiftUI

enum NASConnectionPhase: Sendable {
    case waiting, reachingServer, authenticating, checkingService
    var title: String {
        switch self {
        case .waiting: return "等待已有连接结束…"
        case .reachingServer: return "正在连接服务器…"
        case .authenticating: return "正在验证账号…"
        case .checkingService: return "正在检查服务权限…"
        }
    }
    var detail: String {
        switch self {
        case .waiting: return "已有恢复或验证请求正在处理。可以随时取消本次连接。"
        case .reachingServer: return "建立 HTTPS 连接并读取 NAS 接口；此时尚未提交密码。"
        case .authenticating: return "正在通过加密连接验证账号与验证码。"
        case .checkingService: return "账号已验证，正在确认所选服务可用。"
        }
    }
    var failureTitle: String {
        switch self {
        case .waiting: return "等待已有连接未完成"
        case .reachingServer: return "连接服务器未完成"
        case .authenticating: return "验证账号失败"
        case .checkingService: return "检查服务权限未完成"
        }
    }
}

// Waiting for another task's value does not inherit cancellation. This waiter releases
// the caller immediately without cancelling a task owned by another NAS service.
private final class NASConnectionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func waitForNASConnectionTask<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) async throws {
    let waiter = NASConnectionWaiter()
    let observer = Task { _ = await task.result; waiter.finish(.success(())) }
    defer { observer.cancel() }
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { waiter.attach($0) }
    } onCancel: { waiter.finish(.failure(CancellationError())) }
    try Task.checkCancellation()
}

@MainActor
final class AppState: ObservableObject {
    @Published var credentials = NASCredentials()
    @Published var client: SynologyClient?
    @Published var fileClient: SynologyClient?
    @Published var monitorClient: SynologyClient?
    @Published var monitorConnectionID = UUID()
    @Published var fileConnectionID = UUID()
    @Published private(set) var activeCredentials: NASCredentials?
    let downloads: NASDownloadManager
    var fileAccountID: String { NASService.accountID(activeCredentials ?? credentials) }
    @Published var connecting = false
    @Published private(set) var connectionPhase: NASConnectionPhase?
    @Published var error: String?
    @Published var connectionID = UUID()
    @Published var remember = true
    @Published var hasSavedConnection = false
    @Published private(set) var restoringService: NASService?
    @Published private(set) var restoreErrors: [NASService: String] = [:]
    private let persistence: ConnectionPersistence
    private let makeClient: (NASCredentials, NASService) throws -> SynologyClient
    private var savedConnection: SavedNASConnection?
    private var automatic = true
    private var manualLoginRequired = false
    private var attempted = Set<NASService>()
    private var epoch = UUID()
    private var restoreTask: Task<Void, Never>?
    private var restoreID = UUID()
    private var authenticationTask: Task<NASSession, Error>?
    private var authenticationID = UUID()
    private var authenticationClient: SynologyClient?
    private let connectionTimeout: Duration
    private var manualConnectionID: UUID?
    private var manualConnectionTask: Task<Bool, Never>?
    private var manualConnectionDeadline: Task<Void, Never>?
    private var manualCandidate: SynologyClient?

    init(persistence: ConnectionPersistence? = nil,
         makeClient: ((NASCredentials, NASService) throws -> SynologyClient)? = nil,
         downloads: NASDownloadManager? = nil,
         connectionTimeout: Duration = .seconds(30)) {
        self.connectionTimeout = connectionTimeout
        #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
        self.persistence = persistence ?? (NASConnectionFixture.enabled ? NASConnectionFixture.persistence() : .keychain)
        self.makeClient = makeClient ?? { account, service in
            if NASConnectionFixture.enabled { return try NASConnectionFixture.makeClient(account, service: service) }
            return try SynologyClient(address: account.address, service: service)
        }
        if persistence == nil && NASConnectionFixture.enabled {
            self.downloads = downloads ?? NASDownloadManager(directory: FileStationFixture.directory())
            self.downloads.transferConfiguration = FileStationFixture.configuration
            loadSavedConnection()
            return
        }
        if persistence == nil && FileStationFixture.enabled {
            self.downloads = NASDownloadManager(directory: FileStationFixture.directory())
            self.downloads.transferConfiguration = FileStationFixture.configuration
            credentials = FileStationFixture.credentials
            activeCredentials = credentials
            automatic = false
            if !FileStationFixture.offline {
                Task {
                    do {
                        let files = try SynologyClient(address: credentials.address, service: .files, session: URLSession(configuration: FileStationFixture.configuration()))
                        try await files.login(credentials, otp: "")
                        fileClient = files
                    } catch { self.error = friendlyError(error) }
                }
            }
            return
        }
        #else
        self.persistence = persistence ?? .keychain
        self.makeClient = makeClient ?? { try SynologyClient(address: $0.address, service: $1) }
        #endif
        self.downloads = downloads ?? NASDownloadManager()
        loadSavedConnection()
    }

    private func loadSavedConnection() {
        do {
            if let saved = try persistence.load() {
                savedConnection = saved; credentials = saved.credentials
                activeCredentials = saved.credentials; hasSavedConnection = true
                automatic = saved.automatic; manualLoginRequired = saved.requiresLogin
            }
        } catch { self.error = friendlyError(error) }
    }

    private func connected(_ service: NASService) -> SynologyClient? {
        switch service {
        case .photos: return client
        case .files: return fileClient
        case .monitor: return monitorClient
        }
    }

    // Each service restores on first use. Switching tabs neither logs out nor repeats failed logins.
    func restoreConnection(service: NASService, retry: Bool = false) async {
        if let restoreTask { await restoreTask.value }
        guard !connecting, connected(service) == nil else { return }
        if retry { attempted.remove(service) }
        guard !attempted.contains(service) else { return }
        // A keychain read may have failed while the device was locked. Try again on use.
        if savedConnection == nil && activeCredentials == nil { loadSavedConnection() }
        guard automatic, let account = activeCredentials else { return }
        guard !manualLoginRequired else {
            restoreErrors[service] = "需要重新验证 NAS 账号，请打开连接设置完成登录。"
            return
        }
        attempted.insert(service)
        let ticket = epoch, id = UUID()
        restoreID = id; restoringService = service; restoreErrors[service] = nil
        let task = Task { await self.restore(account: account, service: service, ticket: ticket) }
        restoreTask = task
        await task.value
        if restoreID == id { restoreTask = nil; restoringService = nil }
    }

    private func restore(account: NASCredentials, service: NASService, ticket: UUID) async {
        var candidate: SynologyClient?
        do {
            let next = try makeClient(account, service); candidate = next
            if let session = savedConnection?.sessions[service.rawValue] {
                do { try await next.resume(session) }
                catch {
                    guard shouldRenewSavedNASSession(error) else { throw error }
                    _ = try await authenticate(next, account: account, otp: "", automaticAttempt: true)
                }
            } else { _ = try await authenticate(next, account: account, otp: "", automaticAttempt: true) }
            try Task.checkCancellation()
            guard epoch == ticket, automatic else { await next.close(); return }
            await install(next, service: service, account: account)
            persistSession(await next.sessionSnapshot(), service: service, account: account)
        } catch {
            if let candidate { await candidate.close() }
            guard epoch == ticket, !Task.isCancelled else { return }
            restoreErrors[service] = friendlyError(error)
            markAuthenticationFailure(error)
        }
    }

    private func install(_ next: SynologyClient, service: NASService, account: NASCredentials) async {
        let ticket = epoch
        await next.setRecovery { [weak self, weak next] in
            guard let self, let next else { throw CancellationError() }
            return try await self.renew(service: service, account: account, client: next, ticket: ticket)
        }
        guard epoch == ticket, automatic else { await next.close(); return }
        switch service {
        case .photos: client = next; connectionID = UUID()
        case .files: fileClient = next; fileConnectionID = UUID()
        case .monitor: monitorClient = next; monitorConnectionID = UUID()
        }
    }

    private func renew(service: NASService, account: NASCredentials, client: SynologyClient, ticket: UUID) async throws -> NASSession {
        guard epoch == ticket, connected(service) === client, !manualLoginRequired, automatic else { throw NASError.api(119) }
        let next = try makeClient(account, service)
        do {
            let session = try await authenticate(next, account: account, otp: "", automaticAttempt: true)
            await next.close()
            try Task.checkCancellation()
            guard epoch == ticket, connected(service) === client, automatic else { throw CancellationError() }
            persistSession(session, service: service, account: account)
            return session
        } catch {
            await next.close()
            if epoch == ticket {
                restoreErrors[service] = friendlyError(error)
                markAuthenticationFailure(error)
            }
            throw error
        }
    }

    private func authenticate(_ next: SynologyClient, account: NASCredentials, otp: String, automaticAttempt: Bool,
                              progress: (@Sendable (NASConnectionPhase) async -> Void)? = nil) async throws -> NASSession {
        // Serialize password submissions across all services, including renewals.
        while let pending = authenticationTask {
            let id = authenticationID
            await progress?(.waiting)
            try await waitForNASConnectionTask(pending)
            if authenticationID == id { authenticationTask = nil; authenticationClient = nil }
        }
        try Task.checkCancellation()
        if automaticAttempt && (manualLoginRequired || !automatic) { throw NASError.api(119) }
        let id = UUID(); authenticationID = id
        let task = Task {
            do {
                try await next.login(account, otp: otp, progress: progress)
                return await next.sessionSnapshot()
            } catch {
                if !Task.isCancelled, account == self.activeCredentials { self.markAuthenticationFailure(error) }
                throw error
            }
        }
        authenticationTask = task; authenticationClient = next
        defer { if authenticationID == id { authenticationTask = nil; authenticationClient = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { await next.close() }
        }
    }

    private func markAuthenticationFailure(_ error: Error) {
        guard needsManualNASLogin(error) else { return }
        manualLoginRequired = true
        if var saved = savedConnection {
            saved.requiresLogin = true
            savedConnection = saved
            do { try persistence.save(saved) } catch { self.error = friendlyError(error) }
        }
    }

    private func persistSession(_ session: NASSession, service: NASService, account: NASCredentials) {
        guard var saved = savedConnection, saved.credentials == account, saved.automatic else { return }
        saved.sessions[service.rawValue] = session
        savedConnection = saved
        do { try persistence.save(saved) }
        catch { self.error = "连接已恢复，但登录状态未能保存：" + friendlyError(error) }
    }

    @discardableResult
    func connect(otp: String = "", service: NASService = .photos) async -> Bool {
        guard !connecting else { return false }
        let id = UUID(), account = credentials, ticket = epoch
        manualConnectionID = id; connecting = true; error = nil; connectionPhase = .waiting
        let task = Task { await self.performConnection(id: id, ticket: ticket, account: account, otp: otp, service: service) }
        manualConnectionTask = task
        manualConnectionDeadline = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.connectionTimeout) } catch { return }
            guard self.manualConnectionID == id else { return }
            let phase = self.connectionPhase ?? .reachingServer
            self.cancelConnection(id: id)
            self.error = phase.failureTitle + "：本次连接已超时，请检查 NAS 地址、HTTPS 服务及当前网络后重试。"
        }
        defer {
            if manualConnectionID == id {
                manualConnectionDeadline?.cancel(); manualConnectionDeadline = nil
                manualConnectionTask = nil; manualCandidate = nil; manualConnectionID = nil
                connecting = false; connectionPhase = nil
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor [weak self] in self?.cancelConnection(id: id) }
        }
    }

    func cancelConnection() {
        guard let id = manualConnectionID else { return }
        cancelConnection(id: id)
    }

    private func cancelConnection(id: UUID) {
        guard manualConnectionID == id else { return }
        manualConnectionID = nil
        manualConnectionTask?.cancel(); manualConnectionTask = nil
        manualConnectionDeadline?.cancel(); manualConnectionDeadline = nil
        let candidate = manualCandidate; manualCandidate = nil
        connecting = false; connectionPhase = nil
        if let candidate { Task { await candidate.close() } }
    }

    private func checkConnection(id: UUID, ticket: UUID) throws {
        try Task.checkCancellation()
        guard manualConnectionID == id, epoch == ticket else { throw CancellationError() }
    }

    private func reportConnectionPhase(_ phase: NASConnectionPhase, id: UUID) {
        if manualConnectionID == id { connectionPhase = phase }
    }

    private func performConnection(id: UUID, ticket: UUID, account: NASCredentials, otp: String, service: NASService) async -> Bool {
        var candidate: SynologyClient?
        do {
            if let restoreTask { try await waitForNASConnectionTask(restoreTask) }
            try checkConnection(id: id, ticket: ticket)
            let next = try makeClient(account, service); candidate = next; manualCandidate = next
            _ = try await authenticate(next, account: account, otp: otp.trimmingCharacters(in: .whitespacesAndNewlines), automaticAttempt: false) { [weak self] phase in
                await self?.reportConnectionPhase(phase, id: id)
            }
            try checkConnection(id: id, ticket: ticket)
            let session = await next.sessionSnapshot()
            let changesAccount = activeCredentials != nil && activeCredentials != account
            let installedEpoch = changesAccount ? UUID() : ticket
            await next.setRecovery { [weak self, weak next] in
                guard let self, let next else { throw CancellationError() }
                return try await self.renew(service: service, account: account, client: next, ticket: installedEpoch)
            }
            try checkConnection(id: id, ticket: ticket)
            var saved = savedConnection?.credentials == account ? savedConnection! : SavedNASConnection(credentials: account)
            saved.automatic = true; saved.requiresLogin = false
            saved.sessions[service.rawValue] = session
            // Keep usable sessions intact until validation and local persistence succeed.
            // No suspension between this final guard, persistence, and publishing the client.
            if remember { try persistence.save(saved) } else { try persistence.delete() }
            var obsolete: [SynologyClient] = []
            if changesAccount {
                epoch = installedEpoch; restoreTask?.cancel()
                authenticationTask?.cancel()
                if let pending = authenticationClient { Task { await pending.close() } }
                downloads.cancelActive(owner: fileAccountID)
                obsolete = [client, fileClient, monitorClient].compactMap { $0 }
                client = nil; fileClient = nil; monitorClient = nil
                connectionID = UUID(); fileConnectionID = UUID(); monitorConnectionID = UUID()
            } else if let previous = connected(service) {
                obsolete = [previous]
                if service == .files { downloads.cancelActive(owner: fileAccountID) }
            }
            activeCredentials = account; automatic = true; manualLoginRequired = false
            savedConnection = remember ? saved : nil; hasSavedConnection = remember
            restoreErrors.removeAll(); attempted.removeAll()
            switch service {
            case .photos: client = next; connectionID = UUID()
            case .files: fileClient = next; fileConnectionID = UUID()
            case .monitor: monitorClient = next; monitorConnectionID = UUID()
            }
            manualCandidate = nil
            // Finish in the same actor turn as publication: a queued deadline must not
            // report a timeout after the new session has already been committed.
            manualConnectionDeadline?.cancel(); manualConnectionDeadline = nil
            manualConnectionTask = nil; manualConnectionID = nil
            connecting = false; connectionPhase = nil
            Task { for previous in obsolete { await previous.close() } }
            return true
        } catch {
            // Failure must not wait for a second network request to log out.
            if let candidate { await candidate.close() }
            guard manualConnectionID == id, epoch == ticket, !Task.isCancelled else { return false }
            self.error = (connectionPhase ?? .reachingServer).failureTitle + "：" + friendlyError(error)
            if account == activeCredentials { markAuthenticationFailure(error) }
            return false
        }
    }

    private func closeConnections(logout: Bool) async {
        cancelConnection()
        epoch = UUID(); restoreTask?.cancel(); authenticationTask?.cancel()
        if let pending = authenticationClient { Task { await pending.close() } }
        downloads.cancelActive(owner: fileAccountID)
        let oldPhotos = client, oldFiles = fileClient, oldMonitor = monitorClient
        client = nil; fileClient = nil; monitorClient = nil
        connectionID = UUID(); fileConnectionID = UUID(); monitorConnectionID = UUID()
        if let oldPhotos { if logout { await oldPhotos.logout() } else { await oldPhotos.close() } }
        if let oldFiles { if logout { await oldFiles.logout() } else { await oldFiles.close() } }
        if let oldMonitor { if logout { await oldMonitor.logout() } else { await oldMonitor.close() } }
    }

    func disconnect() async {
        automatic = false; attempted.removeAll(); restoreErrors.removeAll()
        if var saved = savedConnection {
            saved.automatic = false; saved.sessions = [:]; savedConnection = saved
            do { try persistence.save(saved) } catch { self.error = friendlyError(error) }
        }
        await closeConnections(logout: true)
    }

    func setBackupBackgroundAccess(_ enabled: Bool) throws {
        guard hasSavedConnection else { if enabled { throw PhotoBackupError.connection }; return }
        try persistence.setBackgroundAccess(enabled)
    }

    func forget() async {
        await disconnect()
        do {
            try persistence.delete(); savedConnection = nil
            activeCredentials = nil; credentials = NASCredentials(); hasSavedConnection = false
        } catch { self.error = friendlyError(error) }
    }
}

@MainActor
final class NASBrowserStore: ObservableObject {
    @Published var photos: [NASPhoto] = []
    @Published var folders: [NASFolder] = []
    @Published var loading = false
    @Published var hasMore = true
    @Published var error: String?
    private var offset = 0
    private var generation = UUID()

    func reset(client: SynologyClient, space: PhotoSpace, folder: Int?) async {
        let ticket = UUID()
        generation = ticket
        photos = []; folders = []; offset = 0; hasMore = true
        loading = true; error = nil
        defer { if generation == ticket { loading = false } }
        do {
            async let batch = client.photos(space: space, folder: folder, offset: 0)
            // Folders are paginated too; don't silently truncate directories at 100.
            var allFolders: [NASFolder] = []
            var folderOffset = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.folders(space: space, parent: folder, offset: folderOffset)
                allFolders += page
                folderOffset += page.count
                if page.count < 100 { break }
            }
            let page = try await batch
            guard ticket == generation, !Task.isCancelled else { return }
            var seenFolders = Set<Int>()
            folders = allFolders.filter { $0.id != folder && seenFolders.insert($0.id).inserted }
            var seenPhotos = Set<Int>()
            photos = page.filter { seenPhotos.insert($0.id).inserted }
            offset = page.count
            hasMore = page.count == 90
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = friendlyError(error)
        }
    }
    func loadMore(client: SynologyClient, space: PhotoSpace, folder: Int?) async {
        guard !loading, hasMore else { return }
        let ticket = generation
        loading = true; error = nil
        defer { if ticket == generation { loading = false } }
        do {
            let page = try await client.photos(space: space, folder: folder, offset: offset)
            guard ticket == generation, !Task.isCancelled else { return }
            var known = Set(photos.map(\.id))
            photos += page.filter { known.insert($0.id).inserted }
            offset += page.count
            hasMore = page.count == 90
        } catch {
            if ticket == generation && !Task.isCancelled { self.error = friendlyError(error) }
        }
    }
}
