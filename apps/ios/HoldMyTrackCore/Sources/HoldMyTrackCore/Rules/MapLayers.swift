/// Where the map's own layers go among the basemap's, which the style document orders.
public enum MapLayers {
    /// Where layer id goes in, or a lifted basemap layer moves to, among the map's current layers
    /// (bottom to top): under the next one after it in order that's already in place, else under
    /// fallback. A basemap layer to lift is in place only once it's above the lowest of own. An
    /// id order doesn't name searches all of it.
    public static func insertionPoint(current: [String], order: [String], id: String, own: Set<String>, fallback: String?) -> String? {
        let lowest = current.firstIndex { own.contains($0) }
        let after = order.firstIndex(of: id).map { $0 + 1 } ?? 0
        return order[after...].first { next in
            guard let at = current.firstIndex(of: next) else { return false }
            return own.contains(next) || (lowest.map { at > $0 } ?? false)
        } ?? fallback
    }

    /// Whether basemap layer id still sits below the lowest of own, so has to be lifted.
    public static func needsLift(current: [String], id: String, own: Set<String>) -> Bool {
        guard let at = current.firstIndex(of: id) else { return false }
        guard let lowest = current.firstIndex(where: { own.contains($0) }) else { return true }
        return lowest >= at
    }
}
