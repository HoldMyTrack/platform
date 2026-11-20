import Foundation

/// Sending recordings (apps/android/docs/SPEC.md FR-3.4, FR-5.2), as values: what's listed and
/// tickable, what goes to `POST /v2/sync/tracks` under `recorded`, what `POST /v2/sync/known`'s
/// answer means for one sent, and the GPX Download writes.
public enum RecordingSync {
    public static let source = "recorded"
    /// A route past this many points is refused by the app, as Android's.
    public static let maxPoints = 50_000
    /// How often a sent recording's ingest is asked about.
    public static let poll: TimeInterval = 2

    /// What `/v2/sync/known` means for a sent recording: still at work (nil), on the map, or its
    /// ingest ended without it, so it's listed again.
    public enum Outcome: Equatable, Sendable { case landed, failed }

    public static func outcome(_ id: String, known: Set<String>, processing: Set<String>) -> Outcome? {
        if processing.contains(id) { return nil }
        return known.contains(id) ? .landed : .failed
    }

    /// What one refused send says, kept beside its row; nil for one the server took.
    public enum Refusal: Equatable, Sendable {
        case tooManyPoints
        case server(String?)
    }

    /// Why the app won't send track, before asking the server.
    public static func refusal(_ track: RecordedTrack) -> Refusal? {
        track.points.count > maxPoints ? .tooManyPoints : nil
    }

    /// The recordings the list shows, newest first: every one on the phone but those sent and awaited.
    public static func listed(_ tracks: [RecordedTrack]) -> [RecordedTrack] {
        tracks.filter { !$0.sent }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Whether Sync can send: something ticked, and not the demo, which can't add anything.
    public static func canSend(ticked: Set<String>, isDemo: Bool) -> Bool { !isDemo && !ticked.isEmpty }

    static func request(_ track: RecordedTrack) -> SyncTracksRequestJSON {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let points = track.points.map { SyncPointJSON(lat: $0.lat, lon: $0.lon, elevationM: $0.ele, time: time.string(from: $0.time)) }
        return SyncTracksRequestJSON(source: source, tracks: [SyncTrackJSON(externalID: track.id, trackType: track.type, name: track.name,
                                                                            description: track.description, points: points)])
    }

    /// The route as GPX 1.1, named as the list names it, elevation only where a fix has it.
    public static func gpx(_ track: RecordedTrack, name: String) -> String {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime]
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="HoldMyTrack" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escaped(name))</name>
            <type>\(escaped(track.type))</type>
            <trkseg>

        """
        for p in track.points {
            out += "      <trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            if let ele = p.ele { out += "<ele>\(ele)</ele>" }
            out += "<time>\(time.string(from: p.time))</time></trkpt>\n"
        }
        out += "    </trkseg>\n  </trk>\n</gpx>\n"
        return out
    }
}

extension APIClient {
    /// One recording under `recorded`: nil when the server took it or already had it, else why not.
    public func sendRecording(_ track: RecordedTrack) async throws -> RecordingSync.Refusal? {
        let json: SyncResultsJSON = try decode(try await send("POST", "v2/sync/tracks", body: RecordingSync.request(track)))
        guard let result = json.results.first(where: { $0.externalID == track.id }) else { return .server(nil) }
        return result.status == "rejected" ? .server(result.error) : nil
    }

    /// Which of ids the account has, and which of those are still being processed.
    public func knownRecordings(_ ids: [String]) async throws -> (known: Set<String>, processing: Set<String>) {
        let json: SyncKnownJSON = try decode(try await send("POST", "v2/sync/known", body: SyncKnownRequestJSON(source: RecordingSync.source, externalIDs: ids)))
        return (Set(json.known), Set(json.processing))
    }
}
