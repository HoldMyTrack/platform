import Foundation

/// Sign in with Apple's parts the app decides over plain values.
public enum AppleSignIn {
    /// The name to send for a new account: Apple's, as the phone's locale writes a full name, or
    /// nil when Apple sent none, as on every authorization after the first.
    public static func name(_ components: PersonNameComponents?, locale: Locale = .current) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        formatter.locale = locale
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
