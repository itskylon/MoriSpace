import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

enum OneDriveOAuth {
    static let redirectURI = "msauth.dev.kylon.MoriPhotos://auth"
    static let scopes = "https://graph.microsoft.com/Files.Read offline_access"
    static let tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!

    static func authorizationURL(clientID: String, state: String, challenge: String) throws -> URL {
        guard UUID(uuidString: clientID) != nil else { throw OneDriveError.invalidClientID }
        var parts = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account")
        ]
        guard let url = parts.url else { throw OneDriveError.configuration }
        return url
    }

    static func authorizationCode(callback: URL, expectedState: String) throws -> String {
        guard let expected = URLComponents(string: redirectURI),
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == expected.scheme?.lowercased(), parts.host == expected.host,
              parts.path == expected.path, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else { throw OneDriveError.invalidCallback }
        let items = parts.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard values("state") == [expectedState], !expectedState.isEmpty,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "error" }).count <= 1,
              items.filter({ $0.name == "code" }).count <= 1 else { throw OneDriveError.invalidCallback }
        if let error = values("error").first {
            guard values("code").isEmpty else { throw OneDriveError.invalidCallback }
            throw error == "access_denied" ? OneDriveError.cancelled : OneDriveError.authorization
        }
        guard let code = values("code").first, !code.isEmpty else { throw OneDriveError.invalidCallback }
        return code
    }

    static func formData(_ fields: [String: String]) -> Data {
        // '+' must be escaped as %2B in application/x-www-form-urlencoded token requests.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

struct OneDrivePKCE: Sendable {
    let verifier: String
    let state: String
    var challenge: String { Self.challenge(verifier: verifier) }
    static func make() throws -> Self { try Self(verifier: random(), state: random()) }
    static func challenge(verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OneDriveError.authorization }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct OneDriveTokenRecord: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

struct OneDriveTokenPersistence: Sendable {
    var save: @Sendable (OneDriveTokenRecord) throws -> Void
    var delete: @Sendable (String) throws -> Void
    static let keychain = Self(save: { try OneDriveKeychain.save($0) }, delete: { try OneDriveKeychain.delete($0) })
}

enum OneDriveKeychain {
    private static func query(_ clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.kylon.MoriPhotos.onedrive.oauth",
         kSecAttrAccount as String: clientID.lowercased(),
         kSecAttrSynchronizable as String: false]
    }
    static func save(_ record: OneDriveTokenRecord) throws {
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(record.clientID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(record.clientID)
            item.merge(attributes) { _, new in new }
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    static func load(clientID: String) throws -> OneDriveTokenRecord? {
        var item = query(clientID)
        item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let record = try? JSONDecoder().decode(OneDriveTokenRecord.self, from: data),
              record.clientID.caseInsensitiveCompare(clientID) == .orderedSame else { throw OneDriveError.needsLogin }
        return record
    }
    static func delete(_ clientID: String) throws {
        let status = SecItemDelete(query(clientID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw OneDriveError.keychain(status) }
    }
}

// Makes disconnect synchronous with respect to token persistence, even while an actor
// is suspended in a token refresh. A finished old request cannot resurrect credentials.
private final class OneDriveCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    func perform<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw OneDriveError.disconnected }
        return try operation()
    }
}

actor OneDriveTokenVault {
    private var record: OneDriveTokenRecord
    private let session: URLSession
    private let persistence: OneDriveTokenPersistence
    private let gate = OneDriveCancellationGate()
    private var refreshTask: (id: UUID, task: Task<String, Error>)?
    private var mayPersist: Bool

    init(record: OneDriveTokenRecord, configuration: URLSessionConfiguration = .ephemeral,
         persistence: OneDriveTokenPersistence = .keychain, persistRefreshes: Bool = true) {
        self.record = record; self.persistence = persistence; self.mayPersist = persistRefreshes
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: OneDriveNoRedirectDelegate(), delegateQueue: nil)
    }

    nonisolated func cancel() { gate.cancel(); session.invalidateAndCancel() }

    func invalidate(deleteSaved: Bool = true) throws {
        cancel(); refreshTask?.task.cancel(); refreshTask = nil
        if deleteSaved { try persistence.delete(record.clientID) }
    }

    func persistAfterValidation() throws {
        try gate.perform { try persistence.save(record) }
        mayPersist = true
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        try Task.checkCancellation(); try gate.perform {}
        if let refreshTask {
            let token = try await refreshTask.task.value
            try Task.checkCancellation(); try gate.perform {}
            return token
        }
        if !forceRefresh, record.expiresAt.timeIntervalSinceNow > 60 { return record.accessToken }
        guard let refresh = record.refreshToken, !refresh.isEmpty else { throw OneDriveError.needsLogin }
        let id = UUID()
        let task = Task { try await self.refresh(refresh) }
        refreshTask = (id, task)
        defer { if refreshTask?.id == id { refreshTask = nil } }
        let token = try await task.value
        try Task.checkCancellation(); try gate.perform {}
        return token
    }

    private func refresh(_ refresh: String) async throws -> String {
        do {
            let next = try await Self.exchange(fields: ["client_id": record.clientID, "grant_type": "refresh_token",
                                                       "refresh_token": refresh, "scope": OneDriveOAuth.scopes],
                                               clientID: record.clientID, previousRefresh: refresh, session: session)
            try Task.checkCancellation()
            try gate.perform { if mayPersist { try persistence.save(next) } }
            record = next
            return next.accessToken
        } catch {
            if error as? OneDriveError == .needsLogin {
                // Only an explicit revoked/expired refresh token clears saved credentials;
                // transient network failures keep them for a later user retry.
                try gate.perform { try persistence.delete(record.clientID) }
                gate.cancel()
            }
            throw error
        }
    }

    static func redeem(code: String, verifier: String, clientID: String,
                       configuration: URLSessionConfiguration = .ephemeral) async throws -> OneDriveTokenRecord {
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: OneDriveNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await exchange(fields: ["client_id": clientID, "grant_type": "authorization_code", "code": code,
                                           "code_verifier": verifier, "redirect_uri": OneDriveOAuth.redirectURI, "scope": OneDriveOAuth.scopes],
                                  clientID: clientID, previousRefresh: nil, session: session)
    }

    private static func exchange(fields: [String: String], clientID: String, previousRefresh: String?, session: URLSession) async throws -> OneDriveTokenRecord {
        var request = URLRequest(url: OneDriveOAuth.tokenURL)
        request.httpMethod = "POST"; request.httpBody = OneDriveOAuth.formData(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { try Task.checkCancellation(); throw OneDriveError.network }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 1024 * 1024 else { throw OneDriveError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let oauth = try? JSONDecoder().decode(TokenError.self, from: data)
            if oauth?.error == "invalid_grant" || oauth?.error == "interaction_required" { throw OneDriveError.needsLogin }
            if ["invalid_client", "unauthorized_client", "invalid_scope", "invalid_request"].contains(oauth?.error ?? "") { throw OneDriveError.configuration }
            if http.statusCode == 429 { throw OneDriveError.throttled }
            if http.statusCode >= 500 { throw OneDriveError.serviceUnavailable }
            throw OneDriveError.authorization
        }
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data), result.token_type.lowercased() == "bearer",
              !result.access_token.isEmpty, !result.access_token.contains(where: { $0.isWhitespace }),
              result.expires_in > 0, result.expires_in.isFinite else { throw OneDriveError.invalidResponse }
        return OneDriveTokenRecord(clientID: clientID, accessToken: result.access_token,
                                   refreshToken: result.refresh_token ?? previousRefresh,
                                   expiresAt: Date().addingTimeInterval(result.expires_in))
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let refresh_token: String?
        let expires_in: Double
    }
    private struct TokenError: Decodable { let error: String }
}

@MainActor
private final class OneDriveBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var window: UIWindow?

    func authenticate(url: URL) async throws -> URL {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw OneDriveError.authorization }
        self.window = window
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: URL(string: OneDriveOAuth.redirectURI)!.scheme) { [weak self] callback, error in
                    Task { @MainActor in
                        if let callback { self?.finish(.success(callback)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.finish(.failure(OneDriveError.cancelled)) }
                        else { self?.finish(.failure(OneDriveError.authorization)) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                webSession = session
                if !session.start() { finish(.failure(OneDriveError.authorization)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? UIWindow() }
    func cancel() { webSession?.cancel(); finish(.failure(OneDriveError.cancelled)) }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil; webSession = nil; window = nil
        pending?.resume(with: result)
    }
}

@MainActor
final class OneDriveSession: ObservableObject {
    static let redirectURI = OneDriveOAuth.redirectURI
    @Published private(set) var client: (any OneDriveServing)?
    @Published private(set) var account: OneDriveAccount?
    @Published private(set) var isConnecting = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let browser = OneDriveBrowserLogin()
    private var vault: OneDriveTokenVault?
    private var graph: OneDriveClient?
    private var generation = UUID()
    private var restorationAttempted = false
    private static let clientIDKey = "onedrive.application-client-id"

    var clientID: String {
        get { defaults.string(forKey: Self.clientIDKey) ?? "" }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != clientID else { return }
            objectWillChange.send()
            let previous = clientID
            clearVisibleConnection()
            if !previous.isEmpty { try? OneDriveKeychain.delete(previous) }
            defaults.set(value, forKey: Self.clientIDKey)
            restorationAttempted = false
        }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    init(client: any OneDriveServing, account: OneDriveAccount, defaults: UserDefaults = .standard) {
        self.defaults = defaults; self.client = client; self.account = account
        restorationAttempted = true
    }

    func restoreIfNeeded(retry: Bool = false) async {
        guard client == nil, !isConnecting, (!restorationAttempted || retry), !clientID.isEmpty else { return }
        restorationAttempted = true; isConnecting = true; error = nil
        let ticket = generation
        defer { if generation == ticket { isConnecting = false } }
        do {
            guard let record = try OneDriveKeychain.load(clientID: clientID) else { return }
            let vault = OneDriveTokenVault(record: record)
            try await establish(vault: vault, ticket: ticket)
        } catch { if generation == ticket { self.error = Self.message(error) } }
    }

    func connect() async {
        guard !isConnecting else { return }
        let applicationID = clientID
        guard UUID(uuidString: applicationID) != nil else { error = OneDriveError.invalidClientID.localizedDescription; return }
        clearVisibleConnection()
        isConnecting = true; error = nil; restorationAttempted = true
        let ticket = generation
        defer { if generation == ticket { isConnecting = false } }
        do {
            let pkce = try OneDrivePKCE.make()
            let url = try OneDriveOAuth.authorizationURL(clientID: applicationID, state: pkce.state, challenge: pkce.challenge)
            let callback = try await browser.authenticate(url: url)
            guard generation == ticket else { throw OneDriveError.disconnected }
            let code = try OneDriveOAuth.authorizationCode(callback: callback, expectedState: pkce.state)
            let record = try await OneDriveTokenVault.redeem(code: code, verifier: pkce.verifier, clientID: applicationID)
            guard generation == ticket else { throw OneDriveError.disconnected }
            try await establish(vault: OneDriveTokenVault(record: record, persistRefreshes: false), ticket: ticket)
        } catch {
            if generation == ticket, !(error is CancellationError), error as? OneDriveError != .cancelled { self.error = Self.message(error) }
        }
    }

    func disconnect() async {
        let oldVault = vault
        let applicationID = clientID
        clearVisibleConnection(); restorationAttempted = true; error = nil
        do {
            if let oldVault { try await oldVault.invalidate() }
            else if !applicationID.isEmpty { try OneDriveKeychain.delete(applicationID) }
        } catch { self.error = Self.message(error) }
    }

    private func establish(vault: OneDriveTokenVault, ticket: UUID) async throws {
        self.vault = vault
        let graph = OneDriveClient(tokenProvider: { force in try await vault.token(forceRefresh: force) })
        self.graph = graph
        do {
            let account = try await graph.account()
            try Task.checkCancellation()
            guard generation == ticket else { throw OneDriveError.disconnected }
            try await vault.persistAfterValidation()
            guard generation == ticket else { throw OneDriveError.disconnected }
            self.account = account; client = graph
        } catch {
            vault.cancel(); await graph.invalidate()
            if generation == ticket { self.vault = nil; self.graph = nil }
            throw error
        }
    }

    private func clearVisibleConnection() {
        generation = UUID(); browser.cancel(); vault?.cancel()
        if let graph { Task { await graph.invalidate() } }
        vault = nil; graph = nil; client = nil; account = nil; isConnecting = false
    }

    private static func message(_ error: Error) -> String {
        (error as? OneDriveError)?.localizedDescription ?? OneDriveError.network.localizedDescription
    }
}
