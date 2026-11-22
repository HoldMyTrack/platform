/// The Edit window's sheet height (apps/android's EditorPlacement): as tall as its content, up to
/// a share of the room the sheet may take, so the map keeps a band to edit on; never below about
/// one field, so the one being typed into stays in sight. Expanding to full height stays possible.
public enum EditSheet {
    public static let maxFraction = 0.55

    /// content is the sheet's fitting height, maximum the most a sheet can take on this screen, in points; the cap is whole points.
    public static func height(content: Double, maximum: Double, minimum: Double) -> Double {
        max(min(content, (maximum * maxFraction).rounded(.down)), min(minimum, maximum))
    }

    /// The segment of count equal ones under x in a control width wide; right to left, the
    /// first segment is the rightmost. Nil before the control has a width.
    public static func segment(at x: Double, width: Double, count: Int, rightToLeft: Bool) -> Int? {
        guard width > 0, count > 0 else { return nil }
        let along = rightToLeft ? width - x : x
        return min(count - 1, max(0, Int((along / (width / Double(count))).rounded(.down))))
    }

    /// A tab's reason read out after another, ended as a sentence so the two don't run together.
    public static func sentence(_ reason: String) -> String {
        reason.hasSuffix(".") || reason.hasSuffix("…") ? reason : reason + "."
    }
}
