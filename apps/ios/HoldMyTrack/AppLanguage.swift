import Foundation
import HoldMyTrackCore

extension AppLanguage {
    /// This run's, from the app bundle's localizations.
    static var current: String { resolve(Bundle.main.preferredLocalizations) }
}
