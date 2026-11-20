import Foundation

/// Which upload tasks belong to the account signed in. A background task keeps the headers it was
/// queued with, so its `Authorization` names the session it went out for.
public enum UploadTasks {
    /// Whether a task queued with authorization was queued by a session in ended: such a task is
    /// cancelled, and whatever it ends with is no note for the account signed in after.
    public static func ofEndedSession(_ authorization: String?, ended: Set<String>) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        return ended.contains(String(authorization.dropFirst("Bearer ".count)))
    }

    /// Whether url is a copy iOS made in inbox for a file another app opened here, which the app
    /// owns and deletes once it is sent or dropped.
    public static func isInboxCopy(_ url: URL, inbox: URL) -> Bool {
        let dir = inbox.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }
}
