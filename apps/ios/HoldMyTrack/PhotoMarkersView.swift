import HoldMyTrackCore
import MapLibre
import UIKit

/// Photo markers (apps/android/docs/SPEC.md FR-2.10), as Android's: each photo of the focused
/// activity or the open Story as its thumbnail in a round frame at its point on the route, or,
/// where several would overlap on screen, one marker for the group, stacked, with a count
/// (PhotoMarkers.groups). The groups are worked out again when the camera rests (regroup), so
/// zooming in splits them; meanwhile place keeps each marker on its point.
///
/// Views over the map rather than a symbol layer, as the web's are HTML markers: there are tens
/// of them, each with its own image, which a style would need as an icon after every style load.
/// The layer lets every touch but a marker's through to the map.
final class PhotoMarkersView: UIView {
    private let images: PhotoImages
    private let onOpen: ([String]) -> Void
    private var items: [PhotoMarkerItem] = []
    private var activeID: String?
    /// One view per group, keyed by its photos' ids.
    private var markers: [String: PhotoMarkerView] = [:]

    init(images: PhotoImages, onOpen: @escaping ([String]) -> Void) {
        self.images = images
        self.onOpen = onOpen
        super.init(frame: .zero)
        accessibilityIdentifier = "photoMarkers"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// What to show: items in route order, the one open (activeID) drawn larger.
    func set(_ items: [PhotoMarkerItem], activeID: String?, on map: MLNMapView) {
        self.items = items
        self.activeID = activeID
        regroup(on: map)
    }

    /// The groups again, from where the photos are on screen now.
    func regroup(on map: MLNMapView) {
        let size = PhotoMarkers.size(zoom: map.zoomLevel)
        guard !items.isEmpty, size != .hidden else {
            clear()
            return
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let points = items.map { item in
            let p = map.convert(CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon), toPointTo: self)
            return ScreenPoint(id: item.id, x: p.x, y: p.y)
        }
        let groups = PhotoMarkers.groups(points, size: size, loneID: nil).map(\.ids)
        let wanted = Dictionary(groups.map { ($0.joined(separator: "|"), $0) }, uniquingKeysWith: { a, _ in a })
        for key in markers.keys where wanted[key] == nil { markers.removeValue(forKey: key)?.removeFromSuperview() }
        for (key, ids) in wanted {
            guard let item = byID[ids[0]] else { continue }
            let view = markers[key] ?? {
                let view = PhotoMarkerView()
                view.addAction(UIAction { [weak self, weak view] _ in
                    guard let ids = view?.ids else { return }
                    self?.onOpen(ids)
                }, for: .touchUpInside)
                addSubview(view)
                markers[key] = view
                return view
            }()
            view.bind(item, ids: ids, active: activeID.map(ids.contains) ?? false, small: size == .small, images: images)
        }
        // The one open over the rest.
        for view in markers.values where view.active { bringSubviewToFront(view) }
        place(on: map)
    }

    /// Every marker on its point again, on each camera move.
    func place(on map: MLNMapView) {
        for view in markers.values {
            guard let item = view.item else { continue }
            view.center = map.convert(CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon), toPointTo: self)
        }
    }

    func clear() {
        markers.values.forEach { $0.removeFromSuperview() }
        markers = [:]
    }
}

/// How a marker looks, in points, beside its diameters (PhotoMarkers.look): Android's
/// PhotoMarkerLook and the web's photoMarkerLook.ts.
struct PhotoMarkerLook {
    /// The ring, and while open.
    let border: CGFloat
    let activeBorder: CGFloat
    /// How far up and right each of a group's two cards behind it shows.
    let stack: CGFloat
    /// A group's count: its pill's height, font size and side padding, and how far it overhangs
    /// the circle at the top and right.
    let countHeight: CGFloat
    let countFont: CGFloat
    let countPad: CGFloat
    let countTop: CGFloat
    let countRight: CGFloat

    static let full = PhotoMarkerLook(border: 2, activeBorder: 2, stack: 3, countHeight: 18, countFont: 11, countPad: 4, countTop: 8, countRight: 10)
    static let small = PhotoMarkerLook(border: 1.5, activeBorder: 2, stack: 2, countHeight: 14, countFont: 10, countPad: 3, countTop: 7, countRight: 9)
}

/// One marker: the thumbnail cropped into a circle in a ring, the surface's color or the
/// accent's while open, and for a group two cards' edges behind it and the count on its corner.
/// The view is square, with room around the circle for the stack and the count, and never under a
/// 44-point target.
private final class PhotoMarkerView: UIControl {
    private(set) var item: PhotoMarkerItem?
    private(set) var ids: [String] = []
    private(set) var active = false
    private var small = false
    private var image: UIImage?

    private var look: PhotoMarkerLook { small ? .small : .full }
    private var diameter: CGFloat {
        let d = PhotoMarkers.look[small ? .small : .full]!
        return active ? d.activeDiameter : d.diameter
    }
    private var side: CGFloat { max(diameter + 24, 44) }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(_ next: PhotoMarkerItem, ids groupIDs: [String], active isActive: Bool, small isSmall: Bool, images: PhotoImages) {
        let sameImage = item?.thumbPath == next.thumbPath
        item = next
        ids = groupIDs
        active = isActive
        small = isSmall
        accessibilityIdentifier = "photoMarker"
        accessibilityLabel = groupIDs.count > 1
            ? String(localized: "Photos: \(groupIDs.count)", comment: "A photo marker standing for several photos, written as label: N.")
            : next.caption ?? String(localized: "Photo")
        if !sameImage {
            image = images.cached(next.thumbPath)
            if image == nil {
                let path = next.thumbPath
                images.thumb(path) { [weak self] loaded in
                    guard let self, self.item?.thumbPath == path else { return }
                    self.image = loaded
                    self.setNeedsDisplay()
                }
            }
        }
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let r = diameter / 2, c = side / 2
        layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: c - r, y: c - r, width: diameter, height: diameter)).cgPath
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let look = look
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = diameter / 2
        let circle = { (center: CGPoint, radius: CGFloat) in
            UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        if ids.count > 1 {
            // Two cards behind, up and to the right, as the web's stacked box-shadows.
            for step in [2.0, 1.0] {
                let d = look.stack * step
                let card = circle(CGPoint(x: c.x + d, y: c.y - d), r)
                UIColor(resource: .surface).setFill()
                card.fill()
                UIColor(resource: .borderStrong).setStroke()
                card.lineWidth = 1
                card.stroke()
            }
        }
        let ringWidth = active ? look.activeBorder : look.border
        UIColor(resource: .surfaceTintStrong).setFill()
        circle(c, r).fill()
        if let image, let context = UIGraphicsGetCurrentContext() {
            let inner = r - ringWidth
            context.saveGState()
            circle(c, inner).addClip()
            let scale = 2 * inner / min(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
        let ring = circle(c, r - ringWidth / 2)
        ring.lineWidth = ringWidth
        UIColor(resource: active ? .accent : .surface).setStroke()
        ring.stroke()
        if ids.count > 1 {
            let text = NSAttributedString(string: "\(ids.count)", attributes: [
                .font: UIFont.systemFont(ofSize: look.countFont, weight: .bold),
                .foregroundColor: UIColor(resource: .onAccent),
            ])
            let h = look.countHeight
            let w = max(h, text.size().width + 2 * look.countPad)
            let right = c.x + r + look.countRight, top = c.y - r - look.countTop
            UIColor(resource: .accent).setFill()
            UIBezierPath(roundedRect: CGRect(x: right - w, y: top, width: w, height: h), cornerRadius: h / 2).fill()
            let size = text.size()
            text.draw(at: CGPoint(x: right - w / 2 - size.width / 2, y: top + h / 2 - size.height / 2))
        }
    }
}
