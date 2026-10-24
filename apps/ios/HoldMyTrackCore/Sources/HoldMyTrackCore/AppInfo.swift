import Foundation

/// The build this is — its release number, commit and build number — and the API origin it
/// talks to, read from Info.plist, where `scripts/stamp-build.sh` writes the build and the
/// commit. The User-Agent carries them so the server can tell iOS builds apart and turn away
/// old ones (root `docs/IMPLEMENTATION.md` §4.33).
public struct AppInfo: Equatable, Sendable {
    public let version: String
    public let commit: String
    public let build: Int
    public let apiBaseURL: URL

    /// What every request to the API sends as its User-Agent.
    public var userAgent: String { "HoldMyTrack-iOS/\(version) (\(commit); \(build))" }

    /// The build described by an Info.plist dictionary, or nil when its API origin isn't an
    /// http or https URL with a host. A missing build number reads as 1, as outside a checkout.
    public static func from(_ info: [String: Any]) -> AppInfo? {
        guard let base = info["HMTAPIBaseURL"] as? String, let url = apiBase(base) else { return nil }
        return AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            commit: info["HMTCommit"] as? String ?? "unknown",
            build: (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 1,
            apiBaseURL: url
        )
    }

    /// An API origin without its trailing slash, so paths join onto it with one.
    public static func apiBase(_ value: String) -> URL? {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
