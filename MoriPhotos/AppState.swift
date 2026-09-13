import SwiftUI

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

    init(persistence: ConnectionPersistence? = nil,
         makeClient: ((NASCredentials, NASService) throws -> SynologyClient)? = nil,
         downloads: NASDownloadManager? = nil) {
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

    private func authenticate(_ next: SynologyClient, account: NASCredentials, otp: String, automaticAttempt: Bool) async throws -> NASSession {
        // Serialize password submissions across all services, including renewals.
        while let pending = authenticationTask {
            let id = authenticationID
            _ = try? await pending.value
            if authenticationID == id { authenticationTask = nil }
        }
        try Task.checkCancellation()
        if automaticAttempt && (manualLoginRequired || !automatic) { throw NASError.api(119) }
        let id = UUID(); authenticationID = id
        let task = Task {
            do {
                try await next.login(account, otp: otp)
                return await next.sessionSnapshot()
            } catch {
                if account == self.activeCredentials { self.markAuthenticationFailure(error) }
                throw error
            }
        }
        authenticationTask = task
        defer { if authenticationID == id { authenticationTask = nil } }
        return try await task.value
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
        connecting = true; error = nil
        defer { connecting = false }
        let account = credentials
        if let restoreTask { await restoreTask.value }
        var candidate: SynologyClient?
        do {
            let next = try makeClient(account, service); candidate = next
            _ = try await authenticate(next, account: account, otp: otp.trimmingCharacters(in: .whitespacesAndNewlines), automaticAttempt: false)
            let session = await next.sessionSnapshot()
            if let previous = activeCredentials, previous != account { await closeConnections(logout: true) }
            else if let previous = connected(service) {
                switch service {
                case .files: downloads.cancelActive(owner: fileAccountID); fileClient = nil
                case .photos: client = nil
                case .monitor: monitorClient = nil
                }
                await previous.close()
            }
            var saved = savedConnection?.credentials == account ? savedConnection! : SavedNASConnection(credentials: account)
            saved.automatic = true; saved.requiresLogin = false
            saved.sessions[service.rawValue] = session
            if remember { try persistence.save(saved) } else { try persistence.delete() }
            activeCredentials = account; automatic = true; manualLoginRequired = false
            savedConnection = remember ? saved : nil; hasSavedConnection = remember
            restoreErrors.removeAll(); attempted.removeAll()
            await install(next, service: service, account: account)
            return true
        } catch {
            if let candidate { await candidate.logout() }
            self.error = friendlyError(error)
            if account == activeCredentials { markAuthenticationFailure(error) }
            return false
        }
    }

    private func closeConnections(logout: Bool) async {
        epoch = UUID(); restoreTask?.cancel()
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
