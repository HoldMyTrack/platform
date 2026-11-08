import Foundation

/// Which requests are HoldMyTrack's own, and so carry the session token and the app's headers.
public enum ApiOrigin {
    /// Whether url is bound for the API at base: the same scheme, host and port, and a path at
    /// or under the base's. Compared parsed, since a string prefix of the base also matches
    /// `https://holdmytrack.com.evil.tld/` and `https://holdmytrack.com@evil.tld/`, and MapLibre
    /// fetches whatever URLs the style document names.
    public static func isAPI(_ url: URL, base: URL) -> Bool {
        guard let u = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let b = URLComponents(url: base, resolvingAgainstBaseURL: true),
              u.user == nil, u.password == nil,
              u.scheme?.lowercased() == b.scheme?.lowercased(),
              u.host?.lowercased() == b.host?.lowercased(),
              port(u) == port(b)
        else { return false }
        var basePath = b.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let path = u.percentEncodedPath
        return basePath.isEmpty || path == basePath || path.hasPrefix(basePath + "/")
    }

    private static func port(_ c: URLComponents) -> Int? {
        if let port = c.port { return port }
        switch c.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
