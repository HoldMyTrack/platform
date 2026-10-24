import Foundation
import HoldMyTrackCore

extension AppInfo {
    /// This build's. Info.plist always carries an origin, so nil only means a broken build.
    static let current: AppInfo = {
        guard let info = from(Bundle.main.infoDictionary ?? [:]) else {
            fatalError("Info.plist has no usable HMTAPIBaseURL; check HMT_API_BASE_URL in apps/ios/Config")
        }
        return info
    }()
}
