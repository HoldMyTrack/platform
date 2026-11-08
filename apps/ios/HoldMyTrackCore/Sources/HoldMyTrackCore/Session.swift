import Foundation

/// The signed-in account as the app uses it, from `GET /v1/auth/me` or a sign-in's response.
public struct Account: Equatable, Sendable {
    public let email: String
    public let isDemo: Bool
    public let emailVerified: Bool
    public let displayName: String
    public let country: String
    public let locale: String
    /// "imperial" or "metric", decided by the server from country (ADR-0048).
    public let unitSystem: String

    public init(email: String, isDemo: Bool, emailVerified: Bool, displayName: String = "", country: String = "", locale: String = "", unitSystem: String = "metric") {
        self.email = email
        self.isDemo = isDemo
        self.emailVerified = emailVerified
        self.displayName = displayName
        self.country = country
        self.locale = locale
        self.unitSystem = unitSystem
    }

    init(_ json: AccountJSON) {
        self.init(
            email: json.email, isDemo: json.isDemo, emailVerified: json.emailVerified, displayName: json.displayName,
            country: json.country, locale: json.locale, unitSystem: json.unitSystem
        )
    }
}

/// What the phone keeps of a session between launches: the token, and the account it was for,
/// so the screens can key what they keep by email before the server has answered.
public struct StoredSession: Codable, Equatable, Sendable {
    public let token: String
    public let email: String
    public let isDemo: Bool

    public init(token: String, email: String, isDemo: Bool) {
        self.token = token
        self.email = email
        self.isDemo = isDemo
    }
}

/// Where a session sends the user, as a value (apps/android/docs/SPEC.md FR-1.2, FR-1.4).
public enum SessionRoute: Equatable, Sendable {
    /// No session: Sign in.
    case signIn
    /// A token restored from the Keychain the server hasn't confirmed yet: check it first, since
    /// a revoked one would otherwise show as a map of refused tiles.
    case verify
    /// The email isn't confirmed: every tile and sync request would be refused.
    case verifyEmail
    /// The first run, as on the web: no Country yet, which decides the units.
    case onboarding
    /// The signed-in app.
    case home

    /// The route for a stored session and, once the server has confirmed it, its account.
    public static func of(stored: StoredSession?, confirmed: Account?) -> SessionRoute {
        guard stored != nil else { return .signIn }
        guard let account = confirmed else { return .verify }
        if !account.emailVerified { return .verifyEmail }
        if !account.isDemo && account.country.isEmpty { return .onboarding }
        return .home
    }
}

/// What a failed session check means for the kept token (apps/android/docs/SPEC.md FR-1.2): only
/// a 401 says the session is over; anything else, the server down included, keeps it for the
/// next try.
public enum SessionCheck {
    public static func signsOut(_ error: APIError) -> Bool {
        if case .http(status: 401, _, _) = error { return true }
        return false
    }
}

/// The key everything the phone keeps per account goes under (apps/android/docs/SPEC.md FR-5.3):
/// the account's email as the server spells it, lowercased, with the demo account's own key.
public enum AccountKey {
    public static let demo = "demo"

    public static func of(email: String, isDemo: Bool) -> String {
        isDemo ? demo : email.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
