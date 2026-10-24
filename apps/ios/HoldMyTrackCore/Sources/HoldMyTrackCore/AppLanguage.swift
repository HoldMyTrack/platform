/// The language the app runs in: the one of its localizations iOS picked from the phone's
/// languages and the app's own setting in Settings (apps/ios/docs/ARCHITECTURE.md §1, D11). Requests
/// send it as Accept-Language, so the server answers in the same one (root docs/SPEC.md FR-13.1).
public enum AppLanguage {
    /// "ru" or "en" for the localizations iOS prefers, first to last.
    public static func resolve(_ preferred: [String]) -> String {
        preferred.first?.lowercased().hasPrefix("ru") == true ? "ru" : "en"
    }

    /// The heading family for a language code: Source Serif 4 for Russian, since Fraunces has
    /// no Cyrillic (tokens.css's :lang(ru) rule), Fraunces otherwise.
    public static func headingFamily(_ language: String?) -> String {
        language?.lowercased().hasPrefix("ru") == true ? "Source Serif 4" : "Fraunces"
    }
}
