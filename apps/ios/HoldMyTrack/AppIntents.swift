import AppIntents
import HoldMyTrackCore

/// The app's App Intents: the Live Activity's Pause or Resume, defined in HoldMyTrackCore, which
/// iOS finds only through this.
struct HoldMyTrackAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HoldMyTrackCoreIntents.self] }
}
