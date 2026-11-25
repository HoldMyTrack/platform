import Foundation

/// A circle where the account's tracks are clipped (root docs/SPEC.md FR-7.1).
public struct PrivateLocation: Equatable, Sendable {
    public let id: String
    public let name: String
    public let lon: Double
    public let lat: Double
    public let radiusM: Int

    /// The server's bounds on a radius.
    public static let radiusRange = 50...2000

    /// radiusM as an account reads it: metres, or whole feet for an imperial one.
    public static func shown(radiusM: Int, imperial: Bool) -> Int { imperial ? Int((Double(radiusM) * 3.28084).rounded()) : radiusM }

    /// How much of a Privacy row's tile a circle of radiusM fills, 0 to 1: on a log scale from
    /// the smallest radius to the largest, so 50 m and 2 km both read (Android's
    /// CirclePreviewView).
    public static func previewShare(radiusM: Int) -> Double {
        let clamped = Double(min(max(radiusM, radiusRange.lowerBound), radiusRange.upperBound))
        return log(clamped / Double(radiusRange.lowerBound)) / log(Double(radiusRange.upperBound) / Double(radiusRange.lowerBound))
    }
}

/// Where the account's latest copy of its data stands (root docs/SPEC.md FR-1.13).
public struct ExportStatus: Equatable, Sendable {
    public enum State: String, Sendable { case none, preparing, ready, failed }

    public struct Part: Equatable, Sendable {
        public let n: Int
        public let size: Int
        /// The file it downloads as.
        public let name: String
        /// Its path on the API.
        public let url: String
    }

    public let state: State
    public let expiresAt: String?
    public let parts: [Part]
}

/// One batch of imports still running.
public struct ActiveImport: Equatable, Sendable {
    public let title: String
    public let done: Int
    public let total: Int
}

/// An import that failed on the server's side, not yet seen (root docs/SPEC.md FR-3.2): a file
/// uploaded or a track synced, with the server's reason in the app's language.
public struct ImportFailure: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let reason: String

    public init(id: Int, title: String, reason: String) {
        self.id = id
        self.title = title
        self.reason = reason
    }

    /// The alert's text: one paragraph per failure, its title and reason.
    public static func message(_ failures: [ImportFailure]) -> String {
        failures.map { "\($0.title): \($0.reason)" }.joined(separator: "\n\n")
    }
}

/// The You tab's calls: the avatar, Private locations, the data export, deleting the account,
/// and the imports still running.
extension APIClient {
    /// An image on the API, the avatar's, with the session.
    public func data(path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: app.apiBaseURL) else { throw APIError.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 30)
        authorize(&request)
        return try await perform(request)
    }

    /// `GET /v2/private-locations`, newest first.
    public func privateLocations() async throws -> [PrivateLocation] {
        let json: [PrivateLocationJSON] = try decode(try await send("GET", "v2/private-locations"))
        return json.map(PrivateLocation.init)
    }

    /// How many of the account's tracks its Private locations hide entirely
    /// (`GET /v2/private-locations/hidden`): the list's Private rows.
    public func hiddenTrackCount() async throws -> Int {
        let json: HiddenTracksJSON = try decode(try await send("GET", "v2/private-locations/hidden"))
        return json.count
    }

    /// `POST /v2/private-locations`, or with id `PATCH` it: the whole circle either way.
    public func savePrivateLocation(id: String?, name: String, lon: Double, lat: Double, radiusM: Int) async throws -> PrivateLocation {
        let body = PrivateLocationInputJSON(name: name, lon: lon, lat: lat, radiusM: radiusM)
        let data = try await send(id == nil ? "POST" : "PATCH", id.map { "v2/private-locations/\($0)" } ?? "v2/private-locations", body: body)
        let json: PrivateLocationJSON = try decode(data)
        return PrivateLocation(json)
    }

    public func deletePrivateLocation(_ id: String) async throws {
        try await delete("v2/private-locations/\(id)")
    }

    /// `GET /v2/account/export`.
    public func exportStatus() async throws -> ExportStatus {
        ExportStatus(try decode(try await send("GET", "v2/account/export")) as ExportStatusJSON)
    }

    /// `POST /v2/account/export`: asks for a copy, or answers with the one being prepared.
    public func requestExport() async throws -> ExportStatus {
        ExportStatus(try decode(try await send("POST", "v2/account/export")) as ExportStatusJSON)
    }

    /// A ready part saved to a temporary file named as the server names it.
    public func download(_ part: ExportStatus.Part) async throws -> URL {
        guard let url = URL(string: part.url, relativeTo: app.apiBaseURL) else { throw APIError.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 600)
        authorize(&request)
        let data = try await perform(request)
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: (part.name as NSString).lastPathComponent)
        try data.write(to: file)
        return file
    }

    /// `DELETE /v2/account`, confirmed by the account's email.
    public func deleteAccount(email: String) async throws {
        _ = try await send("DELETE", "v2/account", body: EmailJSON(email: email))
    }

    /// `GET /v2/uploads/active`: imports still running.
    public func activeImports() async throws -> [ActiveImport] {
        let json: UploadsActiveJSON = try decode(try await send("GET", "v2/uploads/active"))
        return json.imports.map { ActiveImport(title: $0.title, done: $0.done, total: $0.total) }
    }

    /// `GET /v2/uploads/active`'s unseen failures, newest first, at most 20.
    public func importFailures() async throws -> [ImportFailure] {
        let json: UploadsActiveJSON = try decode(try await send("GET", "v2/uploads/active"))
        return json.failures.map { ImportFailure(id: $0.id, title: $0.title, reason: $0.reason) }
    }

    /// `POST /v2/uploads/seen`: the failure id is dismissed, so no later check shows it again.
    public func dismissImportFailure(_ id: Int) async throws {
        _ = try await send("POST", "v2/uploads/seen", body: UploadSeenJSON(id: id))
    }

    /// `POST /v2/tracks/upload` for one file whose multipart body is at body (UploadBody),
    /// for a background URLSession, which sends from a file: the session's headers, the
    /// token included, and the body's type.
    public func uploadRequest(boundary: String) -> URLRequest {
        var request = request("POST", "v2/tracks/upload")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        return request
    }

    /// What a finished upload task says, error being its transport error: `.sent` when it went,
    /// `.already` when the file was imported before, `.unreachable` when no answer came (a cancel
    /// by iOS included), else the server's reason.
    public static func uploadOutcome(error: Error? = nil, status: Int, body: Data) -> UploadOutcome {
        if error != nil { return .unreachable }
        if (200..<300).contains(status) {
            let json = try? JSONDecoder().decode(UploadResultJSON.self, from: body)
            return json?.status == "already_processed" ? .already : .sent
        }
        let failure = try? JSONDecoder().decode(ErrorJSON.self, from: body)
        return .refused(failure?.message ?? "")
    }
}

public enum UploadOutcome: Equatable, Sendable {
    case sent, already, unreachable
    /// The server's reason, empty when it gave none.
    case refused(String)
}

/// A multipart body holding one file under `file`, as `POST /v2/tracks/upload` takes it.
public enum UploadBody {
    public static func write(file: URL, name: String, boundary: String, to out: URL) throws {
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try body.write(to: out)
    }
}

extension PrivateLocation {
    init(_ json: PrivateLocationJSON) {
        self.init(id: json.id, name: json.name, lon: json.lon, lat: json.lat, radiusM: json.radiusM)
    }
}

extension ExportStatus {
    init(_ json: ExportStatusJSON) {
        self.init(
            state: State(rawValue: json.state) ?? .none,
            expiresAt: json.expiresAt,
            parts: (json.parts ?? []).map { Part(n: $0.n, size: $0.size, name: $0.name, url: $0.url) }
        )
    }
}