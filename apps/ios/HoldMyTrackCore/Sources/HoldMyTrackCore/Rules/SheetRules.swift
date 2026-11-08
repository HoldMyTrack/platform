/// Where the map's Activities sheet rests (apps/android/docs/SPEC.md FR-2.7): its head alone,
/// half the map, or nearly all of it.
public enum SheetDetent: Int, Equatable, Sendable, CaseIterable {
    case collapsed, half, expanded
}

public enum SheetRules {
    /// The sheet's height at each detent, in a container height tall whose top topInset is kept
    /// clear (the map's top row), with a head of headHeight: never shorter than its head, never
    /// taller than the room below the top row, half in between.
    public static func heights(container: Double, topInset: Double, head: Double) -> [SheetDetent: Double] {
        let expanded = max(head, container - topInset)
        let half = min(expanded, max(head, container / 2))
        return [.collapsed: head, .half: half, .expanded: expanded]
    }

    /// The detent a drag released at height with velocity (points a second, up positive) comes
    /// to rest at: the one nearest where the motion would carry it in a fifth of a second, so a
    /// flick moves on a detent and a slow release settles on the nearest.
    public static func resting(height: Double, velocity: Double, heights: [SheetDetent: Double]) -> SheetDetent {
        let projected = height + velocity * 0.2
        return SheetDetent.allCases.min { a, b in
            abs((heights[a] ?? 0) - projected) < abs((heights[b] ?? 0) - projected)
        } ?? .collapsed
    }

    /// The handle's tap: a closed sheet opens halfway, an open one closes.
    public static func toggled(_ detent: SheetDetent) -> SheetDetent {
        detent == .collapsed ? .half : .collapsed
    }
}

/// Which activity a tap on the map picks (apps/android/docs/SPEC.md FR-2.7: a track within 14
/// points of the finger).
public enum TrackTap {
    /// How far from the finger a track still counts as tapped.
    public static let radius = 14.0

    /// The layers a tap is asked about: the tracks group's lines, which draw every track the
    /// panel lists; hidden tracks are filtered out of them, so a tap never picks one.
    public static func layerIDs(_ document: LayersDocument) -> Set<String> {
        Set(document.groups.filter { $0.id == "tracks" }.flatMap(\.layers)
            .filter { $0["type"]?.string == "line" }
            .compactMap { $0["id"]?.string })
    }

    /// The tapped activity from the features under the finger, topmost first, each its `id`
    /// attribute: the first that is an activity the panel lists, so a stale tile's track of a
    /// deleted activity is passed over.
    public static func pick(_ ids: [String?], listed: Set<String>) -> String? {
        ids.lazy.compactMap { $0 }.first { listed.contains($0) }
    }
}