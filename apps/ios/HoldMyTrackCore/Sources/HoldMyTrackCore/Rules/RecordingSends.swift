/// What sending the saved recordings decides, as values (apps/android/docs/SPEC.md FR-5.2): each
/// goes without a tick, since Save was the choice (ADR-0039). The cases are
/// testdata/client-rules/recording-send-*.json, which Android's RecordingSendRules runs too.
public enum RecordingSends {
    /// The demo account's recordings stay on the phone: the server refuses its uploads.
    public static func sends(emailVerified: Bool, isDemo: Bool) -> Bool { emailVerified && !isDemo }

    /// Of the recordings, those to send now, newest first: none the server has taken, none swiped
    /// aside, none held by an open screen about it, and none refused since launch unless the user
    /// asked again (retry), so a refusal isn't sent on every return to the app. Those whose last
    /// request failed (setBack, the latest last) go last in that order, or one that stops every
    /// send would keep the rest on the phone.
    public static func toSend(_ recordings: [RecordedTrack], hidden: Set<String>, held: Set<String>, refused: Set<String>, setBack: [String], retry: Bool) -> [RecordedTrack] {
        let going = recordings.filter { !$0.sent && !hidden.contains($0.id) && !held.contains($0.id) && (retry || !refused.contains($0.id)) }
            .sorted { $0.startedAt > $1.startedAt }
        return going.filter { !setBack.contains($0.id) } + setBack.flatMap { id in going.filter { $0.id == id } }
    }

    /// How many recordings wait to be sent: none sent, none swiped aside, and none of the demo
    /// account's. Library's badge, its + and the Sync sheet's Retry line count them.
    public static func waiting(_ recordings: [RecordedTrack], hidden: Set<String>, isDemo: Bool) -> Int {
        isDemo ? 0 : recordings.filter { !$0.sent && !hidden.contains($0.id) }.count
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

    /// Whether error says nothing from the server: the recording's fault, too long to upload or to
    /// handle, or the connection's.
    public static func unanswered(_ error: APIError) -> Bool {
        switch error {
        case .unreachable, .http(status: 408, _, _), .http(status: 502, _, _), .http(status: 504, _, _): true
        default: false
        }
    }

    /// Only a failure every recording would meet stops the send, or one the server can't take
    /// would keep all those after it on the phone; only an answer about the recording itself
    /// refuses it. Two in a row with no answer (afterUnanswered) say it's the connection.
    public static func failure(_ error: APIError, afterUnanswered: Bool) -> Failure {
        if unanswered(error) { return afterUnanswered ? .stop : .next }
        return switch error {
        case .unreadable, .http(status: 500, _, _): .next
        case .http(status: 400, _, _), .http(status: 413, _, _), .http(status: 422, _, _): .refuse(.server(error.serverMessage))
        default: .stop
        }
    }

    /// What Delete does with a recording, as the phone has it when the question is answered.
    public enum Deletion: Equatable, Sendable {
        case deleted
        /// Being sent or on its way: it lands whatever the phone keeps.
        case sending
        /// Off the phone already, on the map.
        case landed
    }

    /// landed, whether the app saw it land: a missing copy may be one deleted already.
    public static func deletion(stored: Bool, going: Bool, landed: Bool) -> Deletion {
        if going { return .sending }
        return !stored && landed ? .landed : .deleted
    }

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