/// What sending the saved recordings decides, as values (apps/android/docs/SPEC.md FR-5.2): each
/// goes without a tick, since Save was the choice (ADR-0039).
public enum RecordingSends {
    /// The demo account's recordings stay on the phone: the server refuses its uploads.
    public static func sends(emailVerified: Bool, isDemo: Bool) -> Bool { emailVerified && !isDemo }

    /// Of the recordings, those to send now: none the server has taken, none swiped aside, none held
    /// by an open screen about it, and none refused since launch unless the user asked again (retry), so a
    /// refusal isn't sent on every return to the app.
    public static func toSend(_ recordings: [RecordedTrack], hidden: Set<String>, held: Set<String>, refused: Set<String>, retry: Bool) -> [RecordedTrack] {
        recordings.filter { !$0.sent && !hidden.contains($0.id) && !held.contains($0.id) && (retry || !refused.contains($0.id)) }
    }

    /// What a failed request means for the rest of the send.
    public enum Failure: Equatable, Sendable {
        /// Nothing would go: the rest waits too.
        case stop
        /// This one waits; the rest goes on.
        case next
        /// The server won't take this one; the rest goes on.
        case refuse(RecordingSync.Refusal)
    }

    /// Only a failure every recording would meet stops the send, or one the server can't take
    /// would keep all those after it on the phone.
    public static func failure(_ error: APIError) -> Failure {
        switch error {
        case .unreachable, .outdated, .http(status: 401, _, _), .http(status: 403, _, _), .http(status: 429, _, _): .stop
        case .unreadable, .http(status: 408, _, _): .next
        case .http(let status, _, _): (400..<500).contains(status) ? .refuse(.server(error.serverMessage)) : .next
        }
    }

    /// The Sync sheet's line for the recordings not sent yet, with Retry: never for the demo account.
    public static func retryShown(isDemo: Bool, unsent: Int) -> Bool { !isDemo && unsent > 0 }

    /// What a row says.
    public enum Note: Equatable, Sendable {
        /// Taken by the server, on its way to the map.
        case processing
        case sending
        /// Not sent yet: it goes on the next return to the app.
        case waiting
        case refused(RecordingSync.Refusal)
    }

    /// nil for one that goes nowhere: the demo account's, or one swiped aside.
    public static func note(sent: Bool, sending: Bool, hidden: Bool, refusal: RecordingSync.Refusal?, isDemo: Bool) -> Note? {
        if isDemo { return nil }
        if sent { return .processing }
        if sending { return .sending }
        if hidden { return nil }
        return refusal.map(Note.refused) ?? .waiting
    }
}