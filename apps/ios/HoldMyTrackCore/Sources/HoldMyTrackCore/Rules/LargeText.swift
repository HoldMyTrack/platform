/// The phone's text size turned up past the point where rows laid out for the default size no
/// longer fit, four numbers across among them: the screens that have them stack them instead of
/// breaking words mid-way. Android's LargeText, at its 1.3× font scale; the cases are
/// testdata/client-rules/large-text.json.
public enum LargeText {
    public static let threshold = 1.3

    /// scale: body text's size at the phone's setting over its default size.
    public static func isOn(scale: Double) -> Bool { scale >= threshold }
}
