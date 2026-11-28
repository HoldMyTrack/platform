/// What Sign in does with its two fields (apps/docs/SPEC.md FR-1.1): the app says only that one
/// is missing; every other rule is the server's, so the two never disagree.
public enum SignInFields: Equatable, Sendable {
    /// Send them: the email trimmed, the password as typed.
    case submit(email: String, password: String)
    /// The email is blank or the password empty.
    case missing

    public static func of(email: String, password: String) -> SignInFields {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty || password.isEmpty ? .missing : .submit(email: address, password: password)
    }
}
