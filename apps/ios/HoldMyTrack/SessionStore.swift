import Foundation
import HoldMyTrackCore
import Security

/// The session the phone keeps between launches, in the Keychain (decision D8 in
/// apps/ios/docs/ARCHITECTURE.md §1), and the account the server confirmed for it this run.
///
/// The Keychain outlives an uninstall, so the first launch of an install, told apart by a
/// UserDefaults marker that an uninstall does remove, deletes whatever an earlier install left.
/// The item is this device's only and readable once the phone has been unlocked after a restart,
/// so a background upload still has the token.
@MainActor
final class SessionStore {
    /// What APIClient reads for each request, from any thread.
    nonisolated let token = TokenBox()

    private(set) var stored: StoredSession?
    /// The account the server confirmed this run; nil until `GET /v1/auth/me` has answered, so a
    /// restored token is never trusted before then (apps/android/docs/SPEC.md FR-1.2).
    private(set) var confirmed: Account?

    private static let service = "dev.holdmytrack.ios.session"
    private static let installedKey = "hmt.installed"

    init(defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: Self.installedKey) {
            Self.deleteItem()
            defaults.set(true, forKey: Self.installedKey)
        }
        #if DEBUG
        // The UI tests start signed out, whatever an earlier run left.
        if ProcessInfo.processInfo.arguments.contains("-hmtSignedOut") { Self.deleteItem() }
        #endif
        stored = Self.readItem()
        token.set(stored?.token)
    }

    var route: SessionRoute { SessionRoute.of(stored: stored, confirmed: confirmed) }

    /// A new session from a sign-in: kept, and confirmed, since the server has just made it.
    func start(_ grant: SessionGrant) {
        let session = StoredSession(token: grant.token, email: grant.account.email, isDemo: grant.account.isDemo)
        Self.writeItem(session)
        stored = session
        confirmed = grant.account
        token.set(grant.token)
    }

    func confirm(_ account: Account) {
        confirmed = account
    }

    /// Forgets the session on the phone, whether or not the server heard the sign-out.
    func clear() {
        Self.deleteItem()
        stored = nil
        confirmed = nil
        token.set(nil)
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    private static func readItem() -> StoredSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    private static func writeItem(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        deleteItem()
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func deleteItem() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The token, readable from any thread: APIClient asks for it on whichever queue a request is
/// built on.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ token: String?) { lock.withLock { value = token } }
    func get() -> String? { lock.withLock { value } }
}
