import Foundation

/// A page of the site the app shows in a web view (root docs/SPEC.md FR-9.6, ADR-0042).
public enum SitePage: String, CaseIterable, Sendable {
    case profile = "/profile"
    case syncHistory = "/sync"
    case settings = "/settings"
    case about = "/about"

    public var path: String { rawValue }

    /// Read again each time the screen comes back to the front: their numbers change with syncs.
    public var refreshOnReturn: Bool { self == .profile || self == .syncHistory }
}

/// A cookie the web view's store gets before the first load.
public struct WebCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let httpOnly: Bool
}

/// How a page is signed in and where its links go (apps/ios/docs/IMPLEMENTATION.md §1.4).
public enum WebPageSession {
    /// The server's session cookie, its in-app marker and its language cookie, the names
    /// `httpapi` and `i18n` read. The marker makes the server render the page without its
    /// header and footer and name the App Store and Health; the language is the app's own, which
    /// the page falls back to when the account's Language is Automatic.
    public static func cookies(token: String, language: String) -> [WebCookie] {
        [
            WebCookie(name: "holdmytrack_session", value: token, httpOnly: true),
            WebCookie(name: "hmt_app", value: "ios", httpOnly: false),
            WebCookie(name: "hmt_lang", value: language == "ru" ? "ru" : "en", httpOnly: false),
        ]
    }

    /// The shared webPageRoute rule over a URL: its scheme, host and port, path, and the map's
    /// `track` and `day` parameters, against the API's base.
    public static func route(_ url: URL, base: URL, page: SitePage, leaving: Bool, onboarding: Bool, post: Bool = false) -> WebRoute {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first { $0.name == name }?.value }
        return WebRoute.of(
            scheme: url.scheme?.lowercased(), authority: authority(url), path: URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
            track: param("track"), day: param("day"),
            baseScheme: base.scheme?.lowercased(), baseAuthority: authority(base), page: page.path, leaving: leaving, onboarding: onboarding, post: post
        )
    }

    /// host[:port], as the rule's cases write it; nil with no host (a mailto: link).
    static func authority(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// Whether a site page that went out of sight was left: popped, dismissed, or its tab no
/// longer the selected one. A screen the page opened over itself (the avatar's photo picker)
/// doesn't count, nor first-run Settings replaced by the map, whose arrival reads the account
/// itself (AppFlow.check). A left page reads the account again and, on return, reloads.
public enum WebPageExit {
    public static func left(popped: Bool, dismissed: Bool, tabLeft: Bool, covered: Bool, onboarding: Bool) -> Bool {
        guard !onboarding, !covered else { return false }
        return popped || dismissed || tabLeft
    }
}
