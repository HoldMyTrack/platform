import Foundation

/// The language the app runs in: the one of its localizations iOS picked from the phone's
/// languages and the app's own setting in Settings (apps/ios/docs/ARCHITECTURE.md §1, D11). Requests
/// send it as Accept-Language, so the server answers in the same one (root docs/SPEC.md FR-13.1).
enum AppLanguage {
    /// "ru" or "en" for the localizations iOS prefers, first to last.
    static func resolve(_ preferred: [String]) -> String {
        preferred.first?.lowercased().hasPrefix("ru") == true ? "ru" : "en"
    }

    static var current: String { resolve(Bundle.main.preferredLocalizations) }
}
