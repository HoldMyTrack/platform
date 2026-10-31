/// What a DELETE's answer means, as a value.
public enum DeleteOutcome {
    /// Whether a DELETE's status means the thing is gone: deleted now, or already (`404`, removed
    /// on the web or another device). The web's `apiError.ts`; all run `testdata/client-rules`.
    public static func done(status: Int) -> Bool {
        (200..<300).contains(status) || status == 404
    }
}