import Foundation

struct NASSession: Codable, Equatable {
    let sid: String
    let token: String?
}

struct SavedNASConnection: Codable {
    var credentials: NASCredentials
    var sessions: [String: NASSession] = [:]
    var automatic = true
    var requiresLogin = false

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let connection = try? decoder.decode(Self.self, from: data) { return connection }
        // Upgrade the original credentials-only keychain entry without losing it.
        return Self(credentials: try decoder.decode(NASCredentials.self, from: data))
    }
}

@MainActor
struct ConnectionPersistence {
    var load: () throws -> SavedNASConnection?
    var save: (SavedNASConnection) throws -> Void
    var delete: () throws -> Void
    var setBackgroundAccess: (Bool) throws -> Void = { _ in }
    static let keychain = Self(load: KeychainStore.load, save: KeychainStore.save, delete: KeychainStore.delete, setBackgroundAccess: KeychainStore.setBackgroundAccess)
}

func isExpiredNASSession(_ error: Error) -> Bool {
    if case NASError.api(let code) = error { return [106, 107, 119].contains(code) }
    if case FileStationError.api(let code) = error { return [106, 107, 119].contains(code) }
    return false
}

func shouldRenewSavedNASSession(_ error: Error) -> Bool {
    if isExpiredNASSession(error) { return true }
    // Some DSM versions omit protected APIs from discovery after the session expires.
    if case NASError.unsupported = error { return true }
    if case FileStationError.unavailable = error { return true }
    return false
}

func needsManualNASLogin(_ error: Error) -> Bool {
    // These are authentication API errors, not File Station's file permission codes.
    if case NASError.api(let code) = error { return (400...410).contains(code) || [106, 107, 119].contains(code) }
    return false
}
