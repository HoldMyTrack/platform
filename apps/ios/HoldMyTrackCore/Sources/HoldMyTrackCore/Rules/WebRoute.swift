/// Where a navigation in a screen showing one of the site's pages goes, from the link's parts and
/// the screen's state: the decision half of the screen's handling, which acts on the answer.
public enum WebRoute: Equatable, Sendable {
    /// The page's own path, or a form's POST to its origin: the web view loads it.
    case stay
    /// Another origin, or another page of the site: a browser, or the app for its scheme.
    case outside
    /// The screen is already leaving: nothing more is done.
    case ignore
    /// The sign-in pages, or the plain map: the screen closes and the map's session check acts.
    case close
    /// The first run's save reached the map: the session is read before the map opens.
    case onboarded
    /// Sync history's View on map.
    case viewOnMap(track: String, day: String)

    /// The route for a link of scheme, authority and path, with the map's track and day query
    /// parameters, against the API's baseScheme and baseAuthority, on the screen showing page.
    /// leaving is whether an earlier navigation already sent the user elsewhere; post is whether
    /// the navigation is a form's POST, which stays, since the server answers it with a page or a
    /// redirect that is routed in turn.
    public static func of(
        scheme: String?, authority: String?, path: String?, track: String?, day: String?,
        baseScheme: String?, baseAuthority: String?, page: String, leaving: Bool, onboarding: Bool, post: Bool
    ) -> WebRoute {
        if scheme != baseScheme || authority != baseAuthority { return .outside }
        let at = path.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        if at == page { return .stay }
        if leaving { return .ignore }
        if post { return .stay }
        switch at {
        case "/signin", "/verify-pending": return .close
        case "/":
            if let track, let day { return .viewOnMap(track: track, day: day) }
            return onboarding ? .onboarded : .close
        default: return .outside
        }
    }
}
