/// The Edit window's sheet height (apps/android's EditorPlacement): as tall as its content, up to
/// a share of the room the sheet may take, so the map keeps a band to edit on; never below about
/// one field, so the one being typed into stays in sight. Expanding to full height stays possible.
public enum EditSheet {
    public static let maxFraction = 0.55

    /// content is the sheet's fitting height, maximum the most a sheet can take on this screen, in points; the cap is whole points.
    public static func height(content: Double, maximum: Double, minimum: Double) -> Double {
        max(min(content, (maximum * maxFraction).rounded(.down)), min(minimum, maximum))
    }
}
