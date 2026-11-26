/// How long a Toast stays: four seconds, six with an action such as Undo, and longer for words
/// that take longer to read, at about fifteen characters a second.
public enum ToastDuration {
    public static func seconds(_ text: String, action: Bool) -> Double {
        max(action ? 6 : 4, Double(text.count) / 15)
    }
}
