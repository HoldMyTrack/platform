import Foundation

/// What a picked photo's EXIF says about when and where it was taken (root docs/SPEC.md FR-16.1),
/// sent as plain upload fields since the redrawn file carries no EXIF.
public struct PhotoExif: Equatable, Sendable {
    /// A moment, when the camera wrote a zone or a GPS clock gives one.
    public var takenAt: Date?
    /// A wall clock with no zone, `2006-01-02T15:04:05`, when nothing gives one.
    public var takenLocal: String?
    public var lat: Double?
    public var lon: Double?

    public init(takenAt: Date? = nil, takenLocal: String? = nil, lat: Double? = nil, lon: Double? = nil) {
        self.takenAt = takenAt
        self.takenLocal = takenLocal
        self.lat = lat
        self.lon = lon
    }
}

/// The EXIF tag values as ImageIO reads them, resolved: Android's PhotoExifFields and the web's
/// readExif, with the same cases. The capture time is DateTimeOriginal, else the file's DateTime.
/// Its zone is OffsetTimeOriginal when the camera wrote one; else the GPS clock, which is UTC:
/// the wall clock minus the GPS time, rounded to the nearest 15 minutes, keeping the camera's own
/// seconds, since a phone can leave the fix a minute or two stale; with neither, the time goes as
/// a zoneless wall clock. A zero position or an all-zero date is a camera writing nothing.
public enum PhotoExifFields {
    private static let quarter = 15 * 60.0
    private static let zones = -12 * 3600.0...14 * 3600.0

    public static func resolve(
        dateTimeOriginal: String?, dateTime: String?, offsetTimeOriginal: String?,
        lat: Double?, lon: Double?, gpsDate: String?, gpsTime: String?
    ) -> PhotoExif {
        var exif = PhotoExif()
        if let lat, let lon, lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 {
            exif.lat = lat
            exif.lon = lon
        }
        let local = wallClock(dateTimeOriginal) ?? wallClock(dateTime)
        let gps = gpsInstant(gpsDate, gpsTime)
        if let local, let offset = offset(offsetTimeOriginal) {
            exif.takenAt = Date(timeIntervalSince1970: local.seconds - offset)
        } else if let local, let gps {
            let zone = ((local.seconds - gps.timeIntervalSince1970) / quarter).rounded() * quarter
            exif.takenAt = zones.contains(zone) ? Date(timeIntervalSince1970: local.seconds - zone) : gps
        } else if let local {
            exif.takenLocal = local.text
        } else if let gps {
            exif.takenAt = gps
        }
        return exif
    }

    /// "YYYY:MM:DD HH:MM:SS" as seconds of a UTC clock and as the wire's text, or nil for
    /// anything else, the all-blank or all-zero value a camera with no clock writes included.
    private static func wallClock(_ value: String?) -> (seconds: Double, text: String)? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              let m = value.wholeMatch(of: /(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2}).*/), m.1 != "0000",
              let seconds = utc(Int(m.1)!, Int(m.2)!, Int(m.3)!, Int(m.4)!, Int(m.5)!, Int(m.6)!) else { return nil }
        return (seconds, "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)")
    }

    /// "+HH:MM" or "-HH:MM" as seconds east of UTC.
    private static func offset(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              let m = value.wholeMatch(of: /([+-])(\d{2}):(\d{2})/) else { return nil }
        return (m.1 == "-" ? -1 : 1) * Double(Int(m.2)! * 3600 + Int(m.3)! * 60)
    }

    /// The GPS date ("YYYY:MM:DD") and time ("HH:MM:SS", or rationals "12/1,34/1,56/1"), UTC.
    private static func gpsInstant(_ date: String?, _ time: String?) -> Date? {
        guard let date = date?.trimmingCharacters(in: .whitespaces),
              let d = date.wholeMatch(of: /(\d{4}):(\d{2}):(\d{2})/),
              let parts = time?.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "," }), parts.count >= 3
        else { return nil }
        let hms = parts.prefix(3).map { rational(String($0)) }
        guard let h = hms[0], let mi = hms[1], let s = hms[2],
              let seconds = utc(Int(d.1)!, Int(d.2)!, Int(d.3)!, Int(h), Int(mi), Int(s)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func rational(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard let n = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let q = parts.count == 2 ? Double(parts[1].trimmingCharacters(in: .whitespaces)).flatMap { $0 == 0 ? nil : $0 } ?? 1 : 1
        return n / q
    }

    private static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        guard parts.isValidDate(in: calendar), let date = calendar.date(from: parts) else { return nil }
        return date.timeIntervalSince1970
    }
}

/// A picked photo ready for `POST /v1/photos`: the redrawn copy, its thumbnail, both JPEG, and
/// what its EXIF said.
public struct PreparedPhoto: Equatable, Sendable {
    public let file: Data
    public let thumb: Data
    public let exif: PhotoExif

    public init(file: Data, thumb: Data, exif: PhotoExif) {
        self.file = file
        self.thumb = thumb
        self.exif = exif
    }
}

/// A picked photo, not yet uploaded. routeAt (epoch seconds) is nil while it waits for the user
/// to place it.
public struct NewPhoto: Equatable, Sendable {
    public let key: String
    public let name: String
    public let prepared: PreparedPhoto
    public var routeAt: Double?
    public var caption: String

    public init(key: String, name: String, prepared: PreparedPhoto, routeAt: Double?, caption: String = "") {
        self.key = key
        self.name = name
        self.prepared = prepared
        self.routeAt = routeAt
        self.caption = caption
    }
}

/// A saved photo's pending changes; a field set is a change.
public struct PhotoChange: Equatable, Sendable {
    public var routeAt: Double?
    public var caption: String?

    public init(routeAt: Double? = nil, caption: String? = nil) {
        self.routeAt = routeAt
        self.caption = caption
    }

    public var isEmpty: Bool { routeAt == nil && caption == nil }
}

/// One row of the Photos tab's list: a saved photo as the draft would leave it, or a new one.
public enum DraftRow: Equatable, Sendable {
    case saved(Photo, routeAt: Double, caption: String, deleted: Bool, changed: Bool)
    case new(NewPhoto, routeAt: Double)

    public var id: String {
        switch self {
        case .saved(let p, _, _, _, _): p.id
        case .new(let p, _): p.key
        }
    }

    public var routeAt: Double {
        switch self {
        case .saved(_, let at, _, _, _), .new(_, let at): at
        }
    }

    public var caption: String {
        switch self {
        case .saved(_, _, let caption, _, _): caption
        case .new(let p, _): p.caption
        }
    }
}

/// The Photos tab's unsaved changes (apps/android/docs/SPEC.md FR-2.10), Android's PhotoDraft and
/// the web's photoDraft.ts: what the Edit window's Save writes after the activity's fields, and
/// what its Cancel throws away. A new photo is prepared on the phone and placed by the placement
/// check or by the user, and goes up only on Save.
public struct PhotoDraft: Equatable, Sendable {
    public private(set) var added: [NewPhoto] = []
    public private(set) var changed: [String: PhotoChange] = [:]
    public private(set) var deleted: [String] = []

    /// Mirrors photos.go's maxPhotoCaptionLen.
    public static let maxCaption = 500

    public init() {}

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && deleted.isEmpty }

    /// How many writes Save will make.
    public var size: Int { added.count + changed.keys.filter { !deleted.contains($0) }.count + deleted.count }

    /// New photos still waiting for the user to place them; Save can't go ahead while any do.
    public var waiting: [NewPhoto] { added.filter { $0.routeAt == nil } }

    /// Every caption Save would write, for its length check.
    public var captions: [String] { added.map(\.caption) + changed.values.compactMap(\.caption) }

    /// Why Save can't go ahead with the photos.
    public enum Invalid: Equatable, Sendable { case waiting, captionTooLong }

    public var invalid: Invalid? {
        if !waiting.isEmpty { return .waiting }
        if captions.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).count > Self.maxCaption }) { return .captionTooLong }
        return nil
    }

    /// The photos as Save would leave them, in route order: saved ones, a deleted one kept and
    /// marked so it can be brought back, and new ones with a place. Waiting ones aren't rows.
    public func rows(_ photos: [Photo]) -> [DraftRow] {
        var rows: [DraftRow] = photos.map { photo in
            let change = changed[photo.id]
            return .saved(photo, routeAt: change?.routeAt ?? photo.routeSeconds, caption: change?.caption ?? photo.caption ?? "",
                          deleted: deleted.contains(photo.id), changed: change != nil)
        }
        rows += added.compactMap { p in p.routeAt.map { .new(p, routeAt: $0) } }
        // Stable, so photos at one moment keep the server's order, new ones after them.
        return rows.enumerated().sorted { ($0.element.routeAt, $0.offset) < ($1.element.routeAt, $1.offset) }.map(\.element)
    }

    public mutating func add(_ photo: NewPhoto) { added.append(photo) }

    public mutating func changeNew(_ key: String, _ change: (inout NewPhoto) -> Void) {
        if let i = added.firstIndex(where: { $0.key == key }) { change(&added[i]) }
    }

    public mutating func removeNew(_ key: String) { added.removeAll { $0.key == key } }

    /// A saved photo moved and/or captioned; a field changed back to what's saved is no change,
    /// and a photo with none left drops out of changed.
    public mutating func change(_ photo: Photo, routeAt: Double? = nil, caption: String? = nil) {
        var next = changed[photo.id] ?? PhotoChange()
        if let routeAt { next.routeAt = routeAt }
        if let caption { next.caption = caption }
        if next.routeAt == photo.routeSeconds { next.routeAt = nil }
        if next.caption == (photo.caption ?? "") { next.caption = nil }
        changed[photo.id] = next.isEmpty ? nil : next
    }

    public mutating func setDeleted(_ id: String, _ on: Bool) {
        deleted.removeAll { $0 == id }
        if on { deleted.append(id) }
    }

    /// A saved photo's change written: it leaves the draft.
    public mutating func changeWritten(_ id: String) { changed[id] = nil }

    /// A saved photo's delete written: it leaves the draft, with whatever change it had.
    public mutating func deleteWritten(_ id: String) {
        changed[id] = nil
        deleted.removeAll { $0 == id }
    }
}

extension Photo {
    /// routeAt in epoch seconds.
    public var routeSeconds: Double { ISOMoment.parse(routeAt)?.timeIntervalSince1970 ?? 0 }
}

/// RFC 3339 moments, with or without fractional seconds.
enum ISOMoment {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func format(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

/// How the Photos tab's unsaved changes alter the markers: photos moved or added (upserts,
/// replacing a saved one with the same id), photos to be deleted (hidden), and the one in hand
/// (activeID), drawn larger and never grouped.
public struct PhotoMarkerOverlay: Equatable, Sendable {
    public let upserts: [PhotoMarkerItem]
    public let hidden: Set<String>
    public let activeID: String?

    public init(upserts: [PhotoMarkerItem], hidden: Set<String>, activeID: String?) {
        self.upserts = upserts
        self.hidden = hidden
        self.activeID = activeID
    }
}

extension PhotoMarkers {
    /// The markers with the Photos tab's unsaved changes merged in.
    public static func items(_ photos: [Photo], mapHidden: Set<String>, overlay: PhotoMarkerOverlay?) -> [PhotoMarkerItem] {
        let items = items(photos, mapHidden: mapHidden)
        guard let overlay else { return items }
        let upserts = Dictionary(overlay.upserts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = items.filter { !overlay.hidden.contains($0.id) }.map { upserts[$0.id] ?? $0 }
        let keptIDs = Set(kept.map(\.id))
        return kept + overlay.upserts.filter { !keptIDs.contains($0.id) }
    }
}

/// Where the placement check put a photo, or that it couldn't.
public enum PhotoPlace: Equatable, Sendable {
    case at(Double)
    case needsPlace
}

extension APIClient {
    /// `POST /v1/photos/place`: where an upload with this EXIF would go on the activity's track,
    /// storing nothing, or needsPlace for the user to choose.
    public func checkPhotoPlace(activityID: String, exif: PhotoExif) async throws -> PhotoPlace {
        let placed = exif.lat != nil && exif.lon != nil
        let body = PhotoPlaceRequestJSON(
            activityID: activityID, takenAt: exif.takenAt.map(ISOMoment.format), takenLocal: exif.takenAt == nil ? exif.takenLocal : nil,
            lat: placed ? exif.lat : nil, lon: placed ? exif.lon : nil
        )
        do {
            let json: PhotoPlaceJSON = try decode(try await send("POST", "v1/photos/place", body: body))
            guard let at = ISOMoment.parse(json.routeAt) else { throw APIError.unreadable }
            return .at(at.timeIntervalSince1970)
        } catch APIError.http(422, "photo_needs_place"?, _) {
            return .needsPlace
        }
    }

    /// `POST /v1/photos`: a prepared photo at routeAt (epoch seconds), the placement check's
    /// answer or the user's, with its caption, already trimmed.
    public func uploadPhoto(activityID: String, photo: PreparedPhoto, routeAt: Double, caption: String) async throws -> Photo {
        var form = MultipartForm()
        form.field("activity_id", activityID)
        form.file("file", filename: "photo.jpg", type: "image/jpeg", data: photo.file)
        form.file("thumb", filename: "thumb.jpg", type: "image/jpeg", data: photo.thumb)
        if let takenAt = photo.exif.takenAt {
            form.field("taken_at", ISOMoment.format(takenAt))
        } else if let local = photo.exif.takenLocal {
            form.field("taken_local", local)
        }
        if let lat = photo.exif.lat, let lon = photo.exif.lon {
            form.field("lat", String(lat))
            form.field("lon", String(lon))
        }
        form.field("route_at", ISOMoment.format(Date(timeIntervalSince1970: routeAt)))
        if !caption.isEmpty { form.field("caption", caption) }
        var upload = request("POST", "v1/photos")
        upload.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = form.finished
        upload.timeoutInterval = 120
        return Photo(try decode(try await perform(upload)) as PhotoJSON)
    }

    /// `PATCH /v1/photos/{id}`: a field given changes; an empty caption clears it, and routeAt is
    /// the photo's new moment on its track, in epoch seconds.
    public func updatePhoto(_ id: String, caption: String?, routeAt: Double?) async throws {
        let body = PhotoPatchJSON(caption: caption, routeAt: routeAt.map { ISOMoment.format(Date(timeIntervalSince1970: $0)) })
        _ = try await send("PATCH", "v1/photos/\(id)", body: body)
    }

    /// `DELETE /v1/photos/{id}`: the photo and both its images; one already gone counts as deleted.
    public func deletePhoto(_ id: String) async throws {
        try await delete("v1/photos/\(id)")
    }
}

/// A multipart/form-data body.
struct MultipartForm {
    let boundary = "HoldMyTrack-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    var finished: Data { body + Data("--\(boundary)--\r\n".utf8) }
}
