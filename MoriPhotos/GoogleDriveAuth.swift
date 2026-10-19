import Combine
import Foundation
import GoogleSignIn
import UIKit

struct GoogleDriveOAuthConfiguration: Equatable {
    let clientID: String
    let callbackScheme: String

    init?(info: [String: Any]) {
        guard let clientID = Self.validatedClientID(info["GIDClientID"] as? String) else { return nil }
        let callbackScheme = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
        let registered = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard registered.contains(where: { $0.caseInsensitiveCompare(callbackScheme) == .orderedSame }) else { return nil }
        self.clientID = clientID
        self.callbackScheme = callbackScheme
    }

    static func validatedClientID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

enum GoogleDriveAuthError: LocalizedError, Equatable {
    case notConfigured, noPresentationWindow, signInRequired, permissionRequired, authorizationInProgress

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Google Drive 尚未配置登录。需要先为森空间配置 Google OAuth 客户端。"
        case .noPresentationWindow: "请回到森空间窗口后再连接 Google Drive。"
        case .signInRequired: "Google 登录已过期或被撤销，请重新连接 Google Drive。"
        case .permissionRequired: "尚未获得 Google Drive 读取权限，请重新连接并允许查看和下载文件。"
        case .authorizationInProgress: "正在等待 Google 授权，请完成登录后再试。"
        }
    }
}

/// Google Sign-In owns the OAuth flow and its Keychain credentials. No password or
/// refresh token is copied into app preferences, download records, or the NAS session.
@MainActor
final class GoogleDriveAuth: ObservableObject {
    static let readonlyScope = "https://www.googleapis.com/auth/drive.readonly"

    @Published private(set) var accountID: String?
    @Published private(set) var accountName: String?
    @Published private(set) var email: String?
    @Published private(set) var isRestoring = false
    @Published private(set) var isAuthorizing = false
    @Published var error: String?

    var isConfigured: Bool { configuration != nil }

    private var configuration: GoogleDriveOAuthConfiguration? {
        GoogleDriveOAuthConfiguration(info: Bundle.main.infoDictionary ?? [:])
    }
    private var restoreTask: Task<Void, Never>?
    private var restoreID: UUID?
    private var generation = 0
    private var allowsAutomaticRestore = true

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if GoogleDriveFixture.enabled {
            accountID = GoogleDriveFixture.owner
            accountName = "Simulator Drive"
            email = "fixture@example.invalid"
        }
        #endif
    }

    func signIn() async {
        if let restoreTask { await restoreTask.value }
        guard !isAuthorizing else { return }
        guard let configuration else { error = GoogleDriveAuthError.notConfigured.localizedDescription; return }
        guard let presenter = Self.presentingViewController() else {
            error = GoogleDriveAuthError.noPresentationWindow.localizedDescription
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuration.clientID)
        generation += 1
        let currentGeneration = generation
        allowsAutomaticRestore = true
        isAuthorizing = true
        error = nil
        defer { if generation == currentGeneration { isAuthorizing = false } }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter, hint: email, additionalScopes: [Self.readonlyScope])
            guard generation == currentGeneration else { return }
            try accept(result.user)
        } catch {
            guard generation == currentGeneration, !Self.isCancellation(error) else { return }
            if Self.requiresNewSignIn(error) {
                GIDSignIn.sharedInstance.signOut()
                clearAccount()
            } else if error as? GoogleDriveAuthError == .permissionRequired {
                clearAccount()
            }
            self.error = Self.message(for: error)
        }
    }

    func restore() async {
        #if DEBUG && targetEnvironment(simulator)
        if GoogleDriveFixture.enabled { return }
        #endif
        if let restoreTask { await restoreTask.value; return }
        guard allowsAutomaticRestore, !isAuthorizing, let configuration else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuration.clientID)
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { clearAccount(); return }
        let currentGeneration = generation
        let operation = UUID()
        restoreID = operation
        isRestoring = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                try self.accept(user)
                self.error = nil
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if Self.requiresNewSignIn(error) {
                    GIDSignIn.sharedInstance.signOut()
                    self.clearAccount()
                    self.error = GoogleDriveAuthError.signInRequired.localizedDescription
                } else if let failure = error as? GoogleDriveAuthError {
                    self.clearAccount()
                    self.error = failure.localizedDescription
                } else {
                    // A transient network failure does not delete a reusable login.
                    self.error = Self.message(for: error)
                }
            }
        }
        restoreTask = task
        await task.value
        if restoreID == operation {
            restoreTask = nil
            restoreID = nil
            isRestoring = false
        }
    }

    func signOut() {
        generation += 1
        allowsAutomaticRestore = false
        restoreTask?.cancel()
        restoreTask = nil
        restoreID = nil
        isRestoring = false
        isAuthorizing = false
        GIDSignIn.sharedInstance.signOut()
        clearAccount()
        error = nil
    }

    func accessToken() async throws -> String {
        #if DEBUG && targetEnvironment(simulator)
        if GoogleDriveFixture.enabled {
            guard allowsAutomaticRestore, accountID == GoogleDriveFixture.owner else { throw GoogleDriveAuthError.signInRequired }
            return GoogleDriveFixture.token
        }
        #endif
        guard isConfigured else { throw GoogleDriveAuthError.notConfigured }
        guard !isAuthorizing else { throw GoogleDriveAuthError.authorizationInProgress }
        if accountID == nil { await restore() }
        guard allowsAutomaticRestore, let user = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleDriveAuthError.signInRequired
        }
        guard user.grantedScopes?.contains(Self.readonlyScope) == true else {
            clearAccount()
            error = GoogleDriveAuthError.permissionRequired.localizedDescription
            throw GoogleDriveAuthError.permissionRequired
        }
        let currentGeneration = generation
        let userID = user.userID
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            guard generation == currentGeneration,
                  GIDSignIn.sharedInstance.currentUser?.userID == userID else { throw CancellationError() }
            try accept(refreshed)
            guard !refreshed.accessToken.tokenString.isEmpty else { throw GoogleDriveAuthError.signInRequired }
            return refreshed.accessToken.tokenString
        } catch {
            guard generation == currentGeneration else { throw CancellationError() }
            if Self.requiresNewSignIn(error) {
                GIDSignIn.sharedInstance.signOut()
                clearAccount()
                self.error = GoogleDriveAuthError.signInRequired.localizedDescription
                throw GoogleDriveAuthError.signInRequired
            }
            if error as? GoogleDriveAuthError == .permissionRequired { clearAccount() }
            if !Self.isCancellation(error) { self.error = Self.message(for: error) }
            throw error
        }
    }

    /// AppAuth's structured error response distinguishes revoked/expired grants
    /// from temporary network errors without showing server response contents.
    static func requiresNewSignIn(_ error: Error) -> Bool {
        if error as? GoogleDriveAuthError == .signInRequired { return true }
        let value = error as NSError
        if value.domain == kGIDSignInErrorDomain,
           [GIDSignInError.hasNoAuthInKeychain.rawValue, GIDSignInError.refreshTokenExpired.rawValue].contains(value.code) { return true }
        if value.domain == "org.openid.appauth.oauth_token",
           let response = value.userInfo["OIDOAuthErrorResponseErrorKey"] as? [String: Any],
           response["error"] as? String == "invalid_grant" { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== value {
            return requiresNewSignIn(underlying)
        }
        return false
    }

    private func accept(_ user: GIDGoogleUser) throws {
        guard user.grantedScopes?.contains(Self.readonlyScope) == true else { throw GoogleDriveAuthError.permissionRequired }
        guard let identifier = user.userID, !identifier.isEmpty else { throw GoogleDriveAuthError.signInRequired }
        accountID = "google-drive:" + identifier
        accountName = user.profile?.name
        email = user.profile?.email
    }

    private func clearAccount() {
        accountID = nil
        accountName = nil
        email = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return value.domain == kGIDSignInErrorDomain && value.code == GIDSignInError.canceled.rawValue
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? GoogleDriveAuthError { return failure.localizedDescription }
        if requiresNewSignIn(error) { return GoogleDriveAuthError.signInRequired.localizedDescription }
        let value = error as NSError
        if value.domain == NSURLErrorDomain { return "无法连接 Google，请检查网络或 VPN 后重试。" }
        if value.domain == kGIDSignInErrorDomain, value.code == GIDSignInError.keychain.rawValue {
            return "无法安全保存 Google 登录，请检查 App 的签名和钥匙串权限。"
        }
        return "Google 授权未完成，请重试；若 Google 显示访问限制，请检查此账号是否在应用的允许用户中。"
    }

    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
                ?? scenes.flatMap(\.windows).first(where: { !$0.isHidden })?.rootViewController else { return nil }
        return topViewController(root)
    }

    private static func topViewController(_ controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topViewController(presented)
        }
        if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(visible)
        }
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return topViewController(selected)
        }
        if let split = controller as? UISplitViewController, let last = split.viewControllers.last {
            return topViewController(last)
        }
        return controller
    }
}
