import Foundation

/// The map's three looks; photos and Stories belong to the first.
public enum MapMode: String, Sendable { case normal, fog, heatmap }

/// A photo marker's place on screen, in points from the map's top-left.
public struct ScreenPoint: Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// Photo markers that would overlap on screen, grouped: the photos of a whole trip seen zoomed
/// out, or several taken at one spot. In ids' order (route order), the first being the one the
/// group shows, at its place.
public struct PhotoCluster: Equatable, Sendable {
    public var ids: [String]
    public let x: Double
    public let y: Double
}

/// One marker in an exported image, in output pixels.
public struct PhotoMarkerPlacement: Equatable, Sendable {
    public let ids: [String]
    public let x: Double
    public let y: Double
    public let diameter: Double
    public let active: Bool
    public let small: Bool
}

/// Which photos the map shows: one activity's, a Story's, or none.
public enum PhotoScope: Equatable, Sendable {
    case activity(String)
    case story(String)
}

public enum PhotoMarkers {
    /// How close two markers' centers may be before they're one group: a little under a full
    /// marker's width (36), so markers that would merely touch stay apart; and for a small one (22).
    public static let clusterRadius = 32.0
    public static let smallClusterRadius = 18.0
    /// Tracks aren't drawn below this zoom (docs/SPEC.md FR-4.1), so neither are photos.
    public static let tracksMinZoom = 4.0
    /// From this zoom up a marker is full size; below it, small, so the tracks still show under
    /// the photos across a whole region.
    public static let fullZoom = 10.0
    /// A group spread wider than this zooms to fit when tapped; a tighter one opens.
    public static let groupSpread = 15.0

    /// A marker's diameter, and while its photo is open, at each size.
    public static let look: [Size: (diameter: Double, activeDiameter: Double)] = [
        .full: (36, 52),
        .small: (22, 36),
    ]

    public enum Size: String, Sendable { case hidden, small, full }

    /// How photo markers are drawn at zoom: not at all where tracks aren't either, small below
    /// fullZoom, full size from it.
    public static func size(zoom: Double) -> Size {
        if zoom < tracksMinZoom { return .hidden }
        return zoom < fullZoom ? .small : .full
    }

    /// Greedy grouping in the given order: each point joins the first group whose anchor (its
    /// first point, where the group's marker sits) is within radius, or starts a group of its
    /// own. Anchoring on a real point rather than a moving centroid keeps a group's marker on the
    /// route and the result stable as points are added.
    public static func cluster(_ points: [ScreenPoint], radius: Double = clusterRadius) -> [PhotoCluster] {
        var clusters: [PhotoCluster] = []
        for p in points {
            if let near = clusters.firstIndex(where: { pow($0.x - p.x, 2) + pow($0.y - p.y, 2) <= pow(radius, 2) }) {
                clusters[near].ids.append(p.id)
            } else {
                clusters.append(PhotoCluster(ids: [p.id], x: p.x, y: p.y))
            }
        }
        return clusters
    }

    /// The markers at a size: the points grouped as they'd overlap, except loneID, which keeps a
    /// marker of its own after the rest.
    public static func groups(_ points: [ScreenPoint], size: Size, loneID: String?) -> [PhotoCluster] {
        var groups = cluster(points.filter { $0.id != loneID }, radius: size == .small ? smallClusterRadius : clusterRadius)
        if let lone = points.first(where: { $0.id == loneID }) { groups.append(PhotoCluster(ids: [lone.id], x: lone.x, y: lone.y)) }
        return groups
    }

    /// The markers an exported image draws (docs/SPEC.md FR-4.10): grouped and sized as the
    /// screen does at zoom, from points in points from the frame's top-left, then scaled to the
    /// image by scale. A marker wholly outside the frame is left out; the active one comes last,
    /// to be drawn on top.
    public static func layout(_ points: [ScreenPoint], zoom: Double, activeID: String?, loneID: String?, width: Double, height: Double, scale: Double) -> [PhotoMarkerPlacement] {
        let size = size(zoom: zoom)
        guard let look = look[size] else { return [] }
        let placed = groups(points, size: size, loneID: loneID).map { group -> PhotoMarkerPlacement in
            let active = activeID.map(group.ids.contains) ?? false
            return PhotoMarkerPlacement(ids: group.ids, x: group.x, y: group.y, diameter: active ? look.activeDiameter : look.diameter, active: active, small: size == .small)
        }.filter { inFrame($0, width: width, height: height) }
        let ordered: [PhotoMarkerPlacement] = placed.filter { !$0.active } + placed.filter { $0.active }
        return ordered.map { m in
            PhotoMarkerPlacement(ids: m.ids, x: m.x * scale, y: m.y * scale, diameter: m.diameter * scale, active: m.active, small: m.small)
        }
    }

    /// Whether any of marker m lies inside a frame of width and height.
    private static func inFrame(_ m: PhotoMarkerPlacement, width: Double, height: Double) -> Bool {
        let r = m.diameter / 2
        return m.x + r >= 0 && m.x - r <= width && m.y + r >= 0 && m.y - r <= height
    }

    /// Whose photos the map shows: in Normal mode, the Edit window's activity when it edits one,
    /// else the selected activity, else the open Story; none in Fog or Heatmap, or while the Edit
    /// window holds several.
    public static func scope(mode: MapMode, editWindowIDs: [String]?, focused: String?, storyID: String?) -> PhotoScope? {
        if mode != .normal { return nil }
        if let editWindowIDs { return editWindowIDs.count == 1 ? .activity(editWindowIDs[0]) : nil }
        if let focused { return .activity(focused) }
        if let storyID { return .story(storyID) }
        return nil
    }

    /// A marker's tap: a group spread over groupSpread meters zooms to fit its bounds (west,
    /// south, east, north), else it opens.
    public static func groupFit(_ group: [(lon: Double, lat: Double)]) -> [Double]? {
        let spread = group.flatMap { a in group.map { b in haversine(a.lat, a.lon, b.lat, b.lon) } }.max() ?? 0
        guard group.count > 1, spread > groupSpread else { return nil }
        let lons = group.map(\.lon)
        let lats = group.map(\.lat)
        return [lons.min()!, lats.min()!, lons.max()!, lats.max()!]
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let h = pow(sin(((lat2 - lat1) * rad) / 2), 2) + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin(((lon2 - lon1) * rad) / 2), 2)
        return 2 * 6_371_008.8 * asin(min(1, h.squareRoot()))
    }
}
