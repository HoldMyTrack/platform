import Foundation
import HoldMyTrackCore
import MapLibre
import UIKit

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

    /// value as the setter for property name takes it: a color as a UIColor, since the setter
    /// throws on a string. Nil for one it can't take, which a reload settles.
    private static func expression(_ name: String, _ value: JSONValue) -> NSExpression? {
        guard name.hasSuffix("-color"), let text = value.string else { return NSExpression(mglJSONObject: value.foundation) }
        guard let c = CSSColor(text) else { return nil }
        return NSExpression(forConstantValue: UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
    }

    /// Applies changes to style; false when one couldn't be, which only a reload settles.
    static func apply(_ changes: [MapStyle.Change], to style: MLNStyle) -> Bool {
        for change in changes {
            if change.kind == "data" {
                guard let source = style.source(withIdentifier: change.layer) as? MLNShapeSource,
                      let data = change.value?.data,
                      let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
                else { return false }
                source.shape = shape
                continue
            }
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
                var value: NSExpression?
                if let given = change.value {
                    guard let parsed = expression(change.name, given) else { return false }
                    value = parsed
                }
                layer.setValue(value, forKey: key)
            }
        }
        return true
    }
}
