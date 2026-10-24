import Foundation
import Yams

/// A schema from the contract: a plain tree of dictionaries, arrays and scalars.
typealias Schema = [String: Any]

/// The API contract, read from services/server/api with every `$ref` inlined — followed relative
/// to the file it's written in — and each `allOf` merged into one schema, so a schema here is a
/// plain tree. The contract has no recursive schemas, so inlining ends.
final class Contract {
    let root: URL
    private var files: [URL: Schema] = [:]
    private var index: URL { root.appending(path: "services/server/api/openapi.yaml") }

    /// The contract of the checkout this file is in.
    init(file: String = #filePath) {
        root = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // HoldMyTrackCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HoldMyTrackCore
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent()
    }

    func response(_ path: String, _ method: String, _ status: Int) throws -> Schema {
        try operation(path, method).obj("responses").obj(String(status)).obj("content").obj("application/json").obj("schema")
    }

    func request(_ path: String, _ method: String) throws -> Schema {
        try operation(path, method).obj("requestBody").obj("content").obj("application/json").obj("schema")
    }

    private func operation(_ path: String, _ method: String) throws -> Schema {
        let item = try load(index).obj("paths").obj(path)
        return try (inline(item, file: index) as? Schema ?? [:]).obj(method)
    }

    /// value with every `$ref` in it replaced by what it points at, read relative to file.
    func inline(_ value: Any, file: URL) throws -> Any {
        if let list = value as? [Any] { return try list.map { try inline($0, file: file) } }
        guard let map = value as? Schema else { return value }
        if let ref = map["$ref"] as? String {
            let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts[0].isEmpty ? file : file.deletingLastPathComponent().appending(path: String(parts[0])).standardizedFileURL
            var node: Any = try load(target)
            for key in (parts.count > 1 ? parts[1] : "").split(separator: "/") {
                let name = key.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = (node as? Schema)?[name] else { throw ContractError("no \(ref) from \(file.lastPathComponent)") }
                node = next
            }
            return try inline(node, file: target)
        }
        if let parts = map["allOf"] as? [Any] {
            var rest = map
            rest["allOf"] = nil
            return Self.merge(try parts.map { try inline($0, file: file) as? Schema ?? [:] } + [rest])
        }
        return try map.mapValues { try inline($0, file: file) }
    }

    private func load(_ file: URL) throws -> Schema {
        if let cached = files[file] { return cached }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let tree = Self.normalize(try Yams.load(yaml: text) as Any) as? Schema else {
            throw ContractError("\(file.path) isn't a YAML mapping")
        }
        files[file] = tree
        return tree
    }

    /// Yams' tree with every key a string: `200:` unquoted is an integer key otherwise.
    private static func normalize(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map(normalize) }
        if let map = value as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: map.map { ("\($0.key.base)", normalize($0.value)) })
        }
        return value
    }

    /// `allOf`'s parts as one schema: their properties together, a property two parts describe
    /// merged too (one part's enum narrowing another's string), and every required field.
    static func merge(_ parts: [Schema]) -> Schema {
        var merged: Schema = [:]
        var properties: [String: Schema] = [:]
        var required: [String] = []
        for part in parts {
            merged.merge(part) { _, new in new }
            for (name, schema) in part["properties"] as? [String: Schema] ?? [:] {
                properties[name, default: [:]].merge(schema) { _, new in new }
            }
            required += part["required"] as? [String] ?? []
        }
        merged["properties"] = properties
        merged["required"] = Array(Set(required))
        return merged
    }
}

struct ContractError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Schema {
    func obj(_ key: String) throws -> Schema {
        guard let value = self[key] as? Schema else { throw ContractError("no \(key) in the contract here: \(keys.sorted())") }
        return value
    }
}
