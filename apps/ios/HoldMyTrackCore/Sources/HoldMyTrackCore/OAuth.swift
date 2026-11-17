import CryptoKit
import Foundation

/// Google's and Facebook's sign-in, and sign-up, run as the server's own browser flow in
/// ASWebAuthenticationSession (decision D7 in apps/ios/docs/ARCHITECTURE.md §1; the flow is
/// root docs/IMPLEMENTATION.md §4.9): started with the S256 challenge of a verifier only the app
/// holds, it ends at `holdmytrack://oauth?code=…`, and only that verifier redeems the code.
public enum OAuth {
    public enum Provider: String, Sendable, CaseIterable {
        case google, facebook
    }

    public static let callbackScheme = "holdmytrack"

    /// A fresh verifier: 32 random bytes, base64url, the 43 characters RFC 7636 asks for.
    public static func newVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        return base64url(Data(bytes))
    }

    /// The S256 challenge for a verifier.
    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Where the browser starts provider's round trip: `/v1/auth/<provider>/start` with the
    /// phone's timezone, for an account it creates, and the app's challenge.
    public static func startURL(_ provider: Provider, base: URL, timezone: String, challenge: String) -> URL {
        var c = URLComponents(url: base.appending(path: "v1/auth/\(provider.rawValue)/start"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "tz", value: timezone), URLQueryItem(name: "app_challenge", value: challenge)]
        return c.url!
    }

    /// The web's sign-up page for the app, whose Turnstile check a native form can't show. The
    /// page's own script gives a new account the browser's timezone.
    public static func signupURL(base: URL, challenge: String) -> URL {
        var c = URLComponents(url: base.appending(path: "signup"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "app_challenge", value: challenge)]
        return c.url!
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a `holdmytrack://oauth` redirect means for a sign-in, as a value. Any app can open that
/// link, and the server's redirect carries no state to tell a real one by, so a forged one must
/// not end a sign-in in progress: only a redeemed code uses the verifier up.
public enum OAuthRedirect: Equatable, Sendable {
    /// Redeem the code with the kept verifier.
    case exchange(code: String)
    /// Show the server's error code; the verifier stays for the real redirect still to come.
    case showError(String?)
    /// No browser sign-in is in flight, or the link isn't the sign-in's: nothing to act on.
    case ignore

    public static func of(_ url: URL, hasVerifier: Bool) -> OAuthRedirect {
        guard hasVerifier,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == OAuth.callbackScheme, c.host?.lowercased() == "oauth"
        else { return .ignore }
        let items = c.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty { return .exchange(code: code) }
        return .showError(items.first(where: { $0.name == "error" })?.value)
    }
}

/// A browser round trip: a provider's sign-in, or the web's sign-up page.
public enum BrowserFlow: Equatable, Sendable {
    case provider(OAuth.Provider)
    case signup
}

/// What a browser round trip's `?error=` code tells the user (root docs/SPEC.md FR-1.9, FR-1.10):
/// the two Facebook refusals a person can act on, else that the flow that opened the sheet
/// failed. The sign-up page shows its own refusals, so a failure reaching the app from it is a
/// generic one.
public enum OAuthFailure: Equatable, Sendable {
    /// Facebook shared no email, and every account needs one.
    case noEmail
    /// Facebook's email belongs to an account already, which Facebook never links to.
    case emailInUse
    /// Anything else, cancelled included: try again.
    case failed(OAuth.Provider)
    /// Sign-up failed: try again.
    case signupFailed

    public static func of(_ code: String?, flow: BrowserFlow) -> OAuthFailure {
        switch flow {
        case .provider(let provider): of(code, provider: provider)
        case .signup: .signupFailed
        }
    }

    public static func of(_ code: String?, provider: OAuth.Provider) -> OAuthFailure {
        switch code {
        case "facebook_no_email": .noEmail
        case "facebook_email_in_use": .emailInUse
        default: .failed(provider)
        }
    }
}
