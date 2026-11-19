import Foundation

/// A rect in the map view's points.
public struct ViewfinderBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }
}

public enum ViewfinderCorner: CaseIterable, Sendable { case nw, ne, sw, se }

/// The room the window keeps clear in a map view, in its points: top for the toolbar, bottom for
/// the image's size under it, side at each side, and minWindow, the smallest a corner can crop it to.
public struct ViewfinderMargins: Equatable, Sendable {
    public let top: Double
    public let bottom: Double
    public let side: Double
    public let minWindow: Double

    public init(top: Double, bottom: Double, side: Double, minWindow: Double) {
        self.top = top
        self.bottom = bottom
        self.side = side
        self.minWindow = minWindow
    }
}

/// The export viewfinder's geometry (apps/ios/docs/SPEC.md FR-2.11): the web's
/// `map/exportViewfinder.ts` and Android's `Viewfinder`, the same rules. The window sits fixed in
/// the middle of the map and the map moves under it. Dragging a corner crops; on release the
/// window settles back to the largest size the area holds and the map zooms by the same factor,
/// so the cropped area fills it again (settle). The window only sets what's in the picture and
/// its shape; the picture's pixels are chosen apart from it, so a phone's screen makes as big an
/// image as any.
public enum Viewfinder {
    /// The part of a width × height map the window may take.
    public static func area(width: Double, height: Double, margins m: ViewfinderMargins) -> ViewfinderBox {
        ViewfinderBox(x: m.side, y: m.top, w: max(m.minWindow, width - 2 * m.side), h: max(m.minWindow, height - m.top - m.bottom))
    }

    /// The largest window of aspect (width ÷ height) that fits area, centred in it; with no
    /// aspect, the whole area.
    public static func fit(_ aspect: Double?, area: ViewfinderBox) -> ViewfinderBox {
        guard let aspect else { return area }
        let w = area.w / area.h >= aspect ? area.h * aspect : area.w
        let h = w / aspect
        return ViewfinderBox(x: area.x + (area.w - w) / 2, y: area.y + (area.h - h) / 2, w: w, h: h)
    }

    /// The window while corner is dragged by (dx, dy) from start: the opposite corner stays put,
    /// the size stays within area and at least minWindow, and with an aspect the shape holds,
    /// scaled by whichever axis the finger has moved further.
    public static func resize(_ start: ViewfinderBox, corner: ViewfinderCorner, dx: Double, dy: Double, aspect: Double?, area: ViewfinderBox, minWindow: Double) -> ViewfinderBox {
        let sx: Double = corner == .ne || corner == .se ? 1 : -1
        let sy: Double = corner == .sw || corner == .se ? 1 : -1
        let ax = sx > 0 ? start.x : start.x + start.w
        let ay = sy > 0 ? start.y : start.y + start.h
        let maxW = sx > 0 ? area.x + area.w - ax : ax - area.x
        let maxH = sy > 0 ? area.y + area.h - ay : ay - area.y
        var w = start.w + sx * dx
        var h = start.h + sy * dy
        if let aspect {
            let kx = w / start.w, ky = h / start.h
            let scale = abs(kx - 1) >= abs(ky - 1) ? kx : ky
            w = start.w * scale
            h = w / aspect
            let shrink = min(maxW / w, maxH / h, 1)
            w *= shrink
            h *= shrink
            let grow = max(minWindow / w, minWindow / h, 1)
            w *= grow
            h *= grow
        } else {
            w = min(max(w, minWindow), max(minWindow, maxW))
            h = min(max(h, minWindow), max(minWindow, maxH))
        }
        return ViewfinderBox(x: sx > 0 ? ax : ax - w, y: sy > 0 ? ay : ay - h, w: w, h: h)
    }

    /// Where a cropped window goes on release: window, the largest of the crop's shape in the
    /// area; zoomDelta, the zoom change that makes the crop fill it; and the crop's middle, in
    /// today's points, which has to end up in the window's.
    public struct Settled: Equatable, Sendable {
        public let window: ViewfinderBox
        public let zoomDelta: Double
        public let focusX: Double
        public let focusY: Double

        public init(window: ViewfinderBox, zoomDelta: Double, focusX: Double, focusY: Double) {
            self.window = window
            self.zoomDelta = zoomDelta
            self.focusX = focusX
            self.focusY = focusY
        }
    }

    public static func settle(_ crop: ViewfinderBox, area: ViewfinderBox) -> Settled {
        let window = fit(crop.w / crop.h, area: area)
        return Settled(window: window, zoomDelta: log2(window.w / crop.w), focusX: crop.centerX, focusY: crop.centerY)
    }

    /// The map point, in today's points of a mapW × mapH map, that has to become the map's middle
    /// for settled's crop middle to land in its window's: the window's offset from the map's
    /// middle, scaled back by the zoom still to come. The window's middle isn't the map's, since
    /// room is kept above it for the toolbar.
    public static func settledCenter(_ settled: Settled, mapW: Double, mapH: Double) -> (x: Double, y: Double) {
        let scale = pow(2, settled.zoomDelta)
        return (settled.focusX + (mapW / 2 - settled.window.centerX) / scale, settled.focusY + (mapH / 2 - settled.window.centerY) / scale)
    }

    /// Whether a settle would change anything visible: a drag that ended within half a point of
    /// where it began leaves the map where it is.
    public static func moved(_ a: ViewfinderBox, _ b: ViewfinderBox) -> Bool {
        abs(a.x - b.x) > 0.5 || abs(a.y - b.y) > 0.5 || abs(a.w - b.w) > 0.5 || abs(a.h - b.h) > 0.5
    }
}

/// A Custom image's sizes, by its long side; the short side follows the window's shape.
public enum CustomSize: String, CaseIterable, Sendable {
    case hd = "HD", twoK = "2K", fourK = "4K"

    public var longSide: Int {
        switch self {
        case .hd: 1920
        case .twoK: 2560
        case .fourK: 3840
        }
    }
}

public enum PresetRow: Sendable { case square, portrait, landscape, story }

/// One platform's image size, from the same guide as the web's `exportPresets.ts`.
public struct ExportPreset: Equatable, Sendable {
    public let id: String
    public let platform: String
    public let row: PresetRow
    public let width: Int
    public let height: Int

    public var aspect: Double { Double(width) / Double(height) }

    /// The web's `EXPORT_PRESETS`, in the same order: by platform, then shape.
    public static let all: [ExportPreset] = [
        ExportPreset(id: "instagram-square", platform: "Instagram", row: .square, width: 1080, height: 1080),
        ExportPreset(id: "instagram-portrait", platform: "Instagram", row: .portrait, width: 1080, height: 1350),
        ExportPreset(id: "instagram-landscape", platform: "Instagram", row: .landscape, width: 1080, height: 566),
        ExportPreset(id: "instagram-story", platform: "Instagram", row: .story, width: 1080, height: 1920),
        ExportPreset(id: "facebook-square", platform: "Facebook", row: .square, width: 1080, height: 1080),
        ExportPreset(id: "facebook-portrait", platform: "Facebook", row: .portrait, width: 1080, height: 1359),
        ExportPreset(id: "facebook-landscape", platform: "Facebook", row: .landscape, width: 1080, height: 566),
        ExportPreset(id: "facebook-story", platform: "Facebook", row: .story, width: 1080, height: 1920),
        ExportPreset(id: "x-square", platform: "X", row: .square, width: 1080, height: 1080),
        ExportPreset(id: "x-landscape", platform: "X", row: .landscape, width: 1280, height: 720),
    ]
}

/// One entry of the viewfinder's one menu: Custom at a size (any shape, its long side fixed), or a
/// platform preset (its own shape and size).
public enum ExportChoice: Equatable, Sendable {
    case custom(CustomSize)
    case preset(ExportPreset)

    /// The window's shape: free for Custom.
    public var aspect: Double? {
        if case .preset(let preset) = self { return preset.aspect }
        return nil
    }

    public static let initial = ExportChoice.custom(.hd)

    /// Every entry, in the menu's order: Custom at each size, then the presets.
    public static let all: [ExportChoice] = CustomSize.allCases.map(ExportChoice.custom) + ExportPreset.all.map(ExportChoice.preset)

    /// The image's pixel size through a window windowW × windowH.
    public func outputSize(windowW: Double, windowH: Double) -> (width: Int, height: Int) {
        switch self {
        case .preset(let preset): return (preset.width, preset.height)
        case .custom(let size):
            let aspect = windowW / windowH, long = size.longSide
            return aspect >= 1
                ? (long, max(1, Int((Double(long) / aspect).rounded())))
                : (max(1, Int((Double(long) * aspect).rounded())), long)
        }
    }
}

/// The image's stats card (root docs/SPEC.md FR-4.7, root docs/IMPLEMENTATION.md §4.3.3) as
/// values: when Show stats can be ticked, what the server is asked to draw, and where the drawn
/// card goes. The web's `exportStats.ts`; the cases are testdata/client-rules/stats-offered.json
/// and stats-card-placement.json.
public enum ExportStats {
    /// What the server is asked to draw: the Checked ids, sorted, and the image's size and theme.
    public struct Request: Equatable, Sendable {
        public let trackIDs: [String]
        public let width: Int
        public let height: Int
        public let dark: Bool

        public init(trackIDs: [String], width: Int, height: Int, dark: Bool) {
            self.trackIDs = trackIDs
            self.width = width
            self.height = height
            self.dark = dark
        }
    }

    /// Whether the map under the marks and the card reads dark: the dark flavor, or Satellite
    /// showing, which a failed imagery doesn't.
    public static func dark(darkFlavor: Bool, satellite: Bool, satelliteFailed: Bool) -> Bool {
        darkFlavor || (satellite && !satelliteFailed)
    }

    /// Which card the window holds: the request wanted now, and the one the held answer (a card,
    /// no card or an error) is for. Capture draws what's previewed only while they agree.
    public struct Hold: Equatable, Sendable {
        public private(set) var wanted: Request?
        public private(set) var answered: Request?

        public init() {}

        /// Whether Capture would draw the card the window previews.
        public var ready: Bool { wanted == nil || wanted == answered }

        /// The request now wanted; true when it's a new one to ask the server for. None wanted
        /// drops the answer with the card, so asking again waits for a fresh one.
        public mutating func want(_ request: Request?) -> Bool {
            guard request != wanted else { return false }
            wanted = request
            if request == nil { answered = nil }
            return request != nil
        }

        /// The server answered request; false for one no longer wanted, whose answer is dropped.
        public mutating func answer(_ request: Request) -> Bool {
            guard request == wanted else { return false }
            answered = request
            return true
        }
    }

    /// Whether Show stats can be ticked: something Checked, and no Trip open, since the Trips tab
    /// has no checkboxes.
    public static func offered(checked: Set<String>, tripID: String?) -> Bool { tripID == nil && !checked.isEmpty }

    /// The card asked for an image width × height, or nil when none is shown.
    public static func request(show: Bool, checked: Set<String>, tripID: String?, width: Int, height: Int, dark: Bool) -> Request? {
        guard show, offered(checked: checked, tripID: tripID) else { return nil }
        return Request(trackIDs: checked.sorted(), width: width, height: height, dark: dark)
    }

    /// Where a card cardWidth × cardHeight goes on an image width × height: at the strip's left
    /// margin, a margin above the watermark's top. The watermark's bottom is the credit plate's at
    /// its nominal descent, so the preview and the image agree without measuring text. Never above
    /// the top margin.
    public static func placement(width: Int, height: Int, cardWidth: Int, cardHeight: Int) -> (x: Double, y: Double) {
        let (font, margin) = ImageMarks.stripMetrics(width: width, height: height)
        let stripBottom = Double(height) - margin + font * 0.2 + font * 0.3
        let watermarkFont = font * ImageMarks.watermarkFontScale
        let watermarkTop = stripBottom - max(watermarkFont * ImageMarks.watermarkLogoScale, watermarkFont)
        return (margin, max(margin, watermarkTop - margin - Double(cardHeight)))
    }
}

/// The style an image is drawn from: the live map's state, so its mode, filters, Checked and
/// focused tracks and pace bands are the image's, without Spots (root docs/IMPLEMENTATION.md
/// §4.3.3) or a tapped Fog place's outline.
public enum ExportStyle {
    public static func state(_ live: MapState) -> MapState {
        var state = live
        state.toggles[Spots.group] = false
        state.vars["fogPlace"] = nil
        return state
    }
}

/// What every exported image carries in its bottom corners, the web export's `drawAttribution` and
/// `drawWatermark` at the same proportions: the basemap's credit on the right over a dark plate,
/// an ODbL requirement on any image the map is in, and the HoldMyTrack logo and wordmark on the
/// left. The drawing is the app's (ExportMarks); its sizes and text are here.
public enum ImageMarks {
    /// Font size as a fraction of the image's shorter side, clamped, so a 566 px landscape and a
    /// 3840 px Custom both read the line at a sensible size.
    static let fontFraction = 0.016
    static let minFont = 12.0
    static let maxFont = 28.0
    static let marginFraction = 0.014
    public static let watermarkFontScale = 1.15
    public static let watermarkLogoScale = 1.7
    public static let watermarkAlpha = 0.8

    /// The credit line's font size and its distance from the corners, for an image width × height.
    public static func stripMetrics(width: Int, height: Int) -> (font: Double, margin: Double) {
        let short = Double(min(width, height))
        let font = min(max(short * fontFraction, minFont), maxFont)
        return (font, max(font * 0.5, short * marginFraction))
    }

    /// The credit as plain text: the basemap's, then the imagery's when the image shows it, each a
    /// source's own HTML attribution with its tags taken out and its entities read.
    public static func creditText(basemap: String?, satellite: String?) -> String {
        [basemap, satellite].compactMap { $0 }
            .map { decodeEntities($0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static let named = ["copy": "©", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    private static func decodeEntities(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-z]+);") else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            let scalar: String? = if name.hasPrefix("#x") {
                UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                named[name]
            }
            if let scalar { out.replaceSubrange(Range(match.range, in: out) ?? whole, with: scalar) }
        }
        return out
    }

    /// A source's attribution in a style document: the served style's, the line the web bakes in,
    /// since a loaded source reports its tile archive's own credit, which leaves Protomaps out.
    public static func attribution(_ style: JSONValue, source: String) -> String? {
        style.object?["sources"]?.object?[source]?.object?["attribution"]?.string
    }
}