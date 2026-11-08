import Foundation
import HoldMyTrackCore
import MapLibre

/// Every request MapLibre sends passes APIClient.prepareMapRequest: the API's tiles get the
/// session, the basemap and imagery only the API's Origin (apps/ios/docs/IMPLEMENTATION.md §2.1).
/// MapLibre has one network configuration per process, so this is set once.
final class MapNetwork: NSObject, MLNNetworkConfigurationDelegate, @unchecked Sendable {
    nonisolated(unsafe) private static var shared: MapNetwork?
    private let api: APIClient

    private init(api: APIClient) {
        self.api = api
    }

    static func install(api: APIClient) {
        let network = MapNetwork(api: api)
        shared = network
        MLNNetworkConfiguration.sharedManager.delegate = network
    }

    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        var prepared = request as URLRequest
        api.prepareMapRequest(&prepared)
        // swiftlint:disable:next force_cast
        return (prepared as NSURLRequest).mutableCopy() as! NSMutableURLRequest
    }
}

/// Applies MapStyle's changes to the loaded style without reloading it. MapLibre's iOS layers
/// name each property after the style spec's in camelCase, with the exceptions below; a change
/// it can't apply by name answers false, and the caller reloads the style instead.
@MainActor
enum MapPatcher {
    /// The style spec's names MapLibre's iOS classes don't simply camelCase.
    private static let renamed: [String: String] = [
        "icon-image": "iconImageName", "icon-rotate": "iconRotation", "icon-size": "iconScale",
        "text-field": "text", "text-font": "textFontNames", "text-size": "textFontSize", "text-rotate": "textRotation",
        "text-max-width": "maximumTextWidth", "text-justify": "textJustification", "line-dasharray": "lineDashPattern",
        "icon-allow-overlap": "iconAllowsOverlap", "text-allow-overlap": "textAllowsOverlap",
        "icon-ignore-placement": "iconIgnoresPlacement", "text-ignore-placement": "textIgnoresPlacement",
        "fill-translate": "fillTranslation", "line-translate": "lineTranslation", "circle-translate": "circleTranslation",
        "circle-pitch-scale": "circleScaleAlignment", "raster-hue-rotate": "rasterHueRotation",
    ]

    static func key(_ name: String) -> String {
        if let renamed = renamed[name] { return renamed }
        let parts = name.split(separator: "-")
        return parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }

    /// Applies changes to style; false when one couldn't be, which only a reload settles.
    static func apply(_ changes: [MapStyle.Change], to style: MLNStyle) -> Bool {
        for change in changes {
            guard let layer = style.layer(withIdentifier: change.layer) else { return false }
            switch (change.kind, change.name) {
            case ("filter", _):
                guard let vector = layer as? MLNVectorStyleLayer else { return false }
                vector.predicate = change.value.map { NSPredicate(mglJSONObject: $0.foundation) }
            case ("layout", "visibility"):
                layer.isVisible = change.value?.string != "none"
            default:
                let key = key(change.name)
                guard layer.responds(to: NSSelectorFromString(key)) else { return false }
                layer.setValue(change.value.map { NSExpression(mglJSONObject: $0.foundation) }, forKey: key)
            }
        }
        return true
    }
}
