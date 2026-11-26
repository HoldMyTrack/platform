import Foundation

/// How the camera frames tracks it flies to.
public enum MapFraming {
    /// The furthest a flight zooms in.
    public static let maxZoom = 15.0

    /// A fit's top and bottom padding (testdata/client-rules/frame-padding.json): under top, above
    /// what covers the bottom of a map height tall plus pad. When they leave no room, as with the
    /// sheet open all the way, the fit keeps a strip of minSpan, taken from the top first.
    public static func padding(height: Double, top: Double, coveredBelow: Double, pad: Double = 48, minSpan: Double = 96) -> (top: Double, bottom: Double) {
        let bottom = coveredBelow + pad
        let fitTop = min(top, max(pad, height - bottom - minSpan))
        let fitBottom = min(bottom, max(pad, height - fitTop - minSpan))
        return (fitTop, fitBottom)
    }

    /// The smallest box `[west, south, east, north]` holding every box, the short way round:
    /// across the antimeridian east passes 180 (Android's BoxUnion).
    public static func union(_ boxes: [[Double]]) -> [Double]? {
        guard !boxes.isEmpty else { return nil }
        let arcs = boxes.map { b -> (Double, Double) in
            let shift = 360 * ((b[0] + 180) / 360).rounded(.down)
            return (b[0] - shift, b[2] - shift)
        }
        var best = (-180.0, 180.0)
        for (start, _) in arcs {
            var end = start
            for (west, east) in arcs { end = max(end, west < start ? east + 360 : east) }
            if end - start < best.1 - best.0 { best = (start, end) }
        }
        return [best.0, boxes.map { $0[1] }.min()!, best.1, boxes.map { $0[3] }.max()!]
    }
}
