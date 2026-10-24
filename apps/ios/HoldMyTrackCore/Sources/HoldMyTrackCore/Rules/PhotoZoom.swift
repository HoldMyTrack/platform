/// The photo viewer's zoom and pan, as plain math over a view: the picture fitted to the stage and
/// centered is scale 1 at (0, 0); scale multiplies that and x, y move its center, in points from
/// the stage's center.
public enum PhotoZoom {
    public struct View: Equatable, Sendable {
        public var scale: Double
        public var x: Double
        public var y: Double

        public init(scale: Double, x: Double, y: Double) {
            self.scale = scale
            self.x = x
            self.y = y
        }
    }

    public struct Size: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public static let fitView = View(scale: 1, x: 0, y: 0)
    /// Past this the 2048 px stored copy is only blur on a typical screen.
    public static let maxScale = 8.0
    /// One press of + or −.
    public static let zoomStep = 1.5
    /// Where a double tap on the fitted picture zooms to.
    public static let doubleTapScale = 3.0

    /// The picture's size at scale 1: as large as fits the stage, never larger than it is.
    public static func fitSize(image: Size, stage: Size) -> Size {
        if image.width <= 0 || image.height <= 0 { return Size(width: 0, height: 0) }
        let ratio = min(stage.width / image.width, stage.height / image.height, 1)
        return Size(width: image.width * ratio, height: image.height * ratio)
    }

    /// Holds the picture where it can be: no smaller than fitted, no larger than maxScale, and an
    /// edge never pulled in past the stage's edge; a picture narrower than the stage stays
    /// centered.
    public static func clamp(_ view: View, fitted: Size, stage: Size) -> View {
        let scale = min(max(view.scale, 1), maxScale)
        let maxX = max(0, (fitted.width * scale - stage.width) / 2)
        let maxY = max(0, (fitted.height * scale - stage.height) / 2)
        return View(scale: scale, x: clamp(view.x, maxX), y: clamp(view.y, maxY))
    }

    /// Scales by factor about point (from the stage's center), so what's under the fingers stays
    /// there.
    public static func zoom(_ view: View, by factor: Double, at point: (x: Double, y: Double), fitted: Size, stage: Size) -> View {
        let scale = min(max(view.scale * factor, 1), maxScale)
        let k = scale / view.scale
        return clamp(View(scale: scale, x: point.x - (point.x - view.x) * k, y: point.y - (point.y - view.y) * k), fitted: fitted, stage: stage)
    }

    public static func pan(_ view: View, dx: Double, dy: Double, fitted: Size, stage: Size) -> View {
        clamp(View(scale: view.scale, x: view.x + dx, y: view.y + dy), fitted: fitted, stage: stage)
    }

    private static func clamp(_ value: Double, _ limit: Double) -> Double {
        // + 0 turns a -0 into 0, so a view that hasn't moved compares equal to fitView.
        min(max(value, -limit), limit) + 0
    }
}
