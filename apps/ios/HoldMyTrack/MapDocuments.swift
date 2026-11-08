import Foundation
import HoldMyTrackCore

/// The map's two documents (ADR-0048), kept on the phone with their ETags so a later launch draws
/// the kept pair at once and only revalidates: the style per flavor and language, the layers
/// document per account and flavor, since it carries the account's tile version.
struct MapDocuments {
    struct Pair {
        let style: JSONValue
        let layers: LayersDocument
    }

    let api: APIClient
    let account: String

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "map", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes what's kept for account: its layers documents, which name its tile version.
    static func forget(account: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "map", directoryHint: .isDirectory)
        let prefix = "layers-\(hash(account))-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    private static func hash(_ account: String) -> UInt64 {
        account.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private func styleName(_ flavor: String, _ language: String) -> String { "style-\(flavor)-\(language)" }
    private func layersName(_ flavor: String) -> String {
        // The email can hold characters a file name can't; its hash can't clash in practice.
        "layers-\(Self.hash(account))-\(flavor)"
    }

    /// The pair kept from an earlier fetch, if both are there and from the same build.
    func kept(flavor: String, language: String) -> Pair? {
        guard let style = read(styleName(flavor, language)).flatMap(JSONValue.parse),
              let layers = read(layersName(flavor)).flatMap(JSONValue.parse).flatMap(LayersDocument.init),
              MapStyle.build(ofStyle: style) == layers.styleBuild
        else { return nil }
        return Pair(style: style, layers: layers)
    }

    /// Both documents, fetched in parallel and revalidated against the kept ones; the style is
    /// fetched again whole when the two come from different builds.
    func fetch(flavor: String, language: String) async throws -> Pair {
        async let styleData = refreshed(styleName(flavor, language)) { try await api.mapStyle(flavor: flavor, language: language, etag: $0) }
        async let layersData = refreshed(layersName(flavor)) { try await api.mapLayers(flavor: flavor, etag: $0) }
        var style = try await styleData
        let layers = try await layersData
        guard let layersDoc = JSONValue.parse(layers).flatMap(LayersDocument.init) else { throw APIError.unreadable }
        if MapStyle.build(ofStyle: JSONValue.parse(style) ?? .null) != layersDoc.styleBuild {
            style = try await refreshed(styleName(flavor, language), revalidate: false) { try await api.mapStyle(flavor: flavor, language: language, etag: $0) }
        }
        guard let styleDoc = JSONValue.parse(style) else { throw APIError.unreadable }
        return Pair(style: styleDoc, layers: layersDoc)
    }

    /// The document called name, fetched with the kept one's ETag when revalidating and there is
    /// one, so a 304 hands the kept copy back.
    private func refreshed(_ name: String, revalidate: Bool = true, _ get: (String?) async throws -> Fetched) async throws -> Data {
        let tag = revalidate && read(name) != nil ? read(name + ".etag").flatMap { String(data: $0, encoding: .utf8) } : nil
        switch try await get(tag) {
        case .notModified:
            if let kept = read(name) { return kept }
            throw APIError.unreadable
        case .document(let data, let tag):
            write(name, data)
            write(name + ".etag", tag.map { Data($0.utf8) })
            return data
        }
    }

    private func read(_ name: String) -> Data? { try? Data(contentsOf: directory.appending(path: name)) }

    private func write(_ name: String, _ data: Data?) {
        let url = directory.appending(path: name)
        if let data { try? data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }
}
