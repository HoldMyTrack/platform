/// What the "check your email" screen's Confirm does with its code field
/// (apps/android/docs/SPEC.md FR-1.4).
public enum VerifyAction: Equatable, Sendable {
    /// Send the code; the server judges it, as it judges sign-in's fields.
    case submit(String)
    /// Nothing typed: ask whether the address was confirmed some other way, by the email's link.
    case check

    public static func of(_ typed: String) -> VerifyAction {
        let code = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? .check : .submit(code)
    }
}
