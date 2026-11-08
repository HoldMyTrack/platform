import Foundation

/// A JSON value, comparable and sendable, for the map's documents: the style and the layers
/// document are combined and compared as data (MapStyle), never as MapLibre objects.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses data, or nil when it isn't JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any)
    }

    public init?(_ any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // JSONSerialization hands booleans over as NSNumber too; CFBoolean tells them apart.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            for item in a {
                guard let v = JSONValue(item) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, item) in o {
                guard let v = JSONValue(item) else { return nil }
                out[k] = v
            }
            self = .object(out)
        default: return nil
        }
    }

    /// The Foundation object JSONSerialization and MapLibre's expression parsers take.
    public var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        }
    }

    /// As JSON text, keys sorted, so equal values give equal text.
    public var data: Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
