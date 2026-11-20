import AppIntents
import HoldMyTrackCore

/// The extension's App Intents: the Live Activity's button names ToggleRecordingIntent, which iOS
/// finds in the package only through this.
struct HoldMyTrackWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HoldMyTrackCoreIntents.self] }
}
