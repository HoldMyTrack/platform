import Foundation

/// A case file's JSON, compared as testdata/client-rules/README.md says: numbers as numbers, so
/// 24.75 and 24.750 agree, and a missing field the same as null.
indirect enum RuleJSON: Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RuleJSON])
    case object([String: RuleJSON])

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let list as [Any]: self = .array(list.map(RuleJSON.init))
        case let map as [String: Any]: self = .object(map.mapValues(RuleJSON.init))
        default: fatalError("not JSON: \(String(describing: any))")
        }
    }

    subscript(key: String) -> RuleJSON {
        if case .object(let map) = self { return map[key] ?? .null }
        return .null
    }

    var isNull: Bool { self == .null }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var list: [RuleJSON]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: RuleJSON]? { if case .object(let o) = self { o } else { nil } }

    /// The field's value, which the case must have.
    func number(_ key: String) -> Double { self[key].double! }
    func int(_ key: String) -> Int { Int(self[key].double!) }
    func strings(_ key: String) -> [String] { self[key].list?.compactMap(\.string) ?? [] }

    /// With every null field dropped, so a missing field and a null agree.
    var normalized: RuleJSON {
        switch self {
        case .object(let map): .object(map.filter { !$0.value.isNull }.mapValues(\.normalized))
        case .array(let list): .array(list.map(\.normalized))
        default: self
        }
    }

    /// Where actual differs from self, numbers within tolerance; nil when they agree.
    func difference(from actual: RuleJSON, tolerance: Double, at path: String = "") -> String? {
        switch (self, actual) {
        case (.number(let e), .number(let a)):
            return abs(e - a) <= tolerance ? nil : "\(path): \(a) is not within \(tolerance) of \(e)"
        case (.array(let e), .array(let a)):
            guard e.count == a.count else { return "\(path): \(a.count) items, expected \(e.count)" }
            for (i, pair) in zip(e, a).enumerated() {
                if let d = pair.0.difference(from: pair.1, tolerance: tolerance, at: "\(path)[\(i)]") { return d }
            }
            return nil
        case (.object(let e), .object(let a)):
            for key in Set(e.keys).union(a.keys).sorted() {
                if let d = (e[key] ?? .null).difference(from: a[key] ?? .null, tolerance: tolerance, at: "\(path).\(key)") { return d }
            }
            return nil
        default:
            return self == actual ? nil : "\(path): \(actual) is not \(self)"
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let b): "\(b)"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : "\(n)"
        case .string(let s): "\"\(s)\""
        case .array(let a): "[\(a.map(\.description).joined(separator: ", "))]"
        case .object(let o): "{\(o.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))}"
        }
    }
}

extension RuleJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: RuleJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, RuleJSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    static func num(_ value: Double) -> RuleJSON { .number(value) }
    static func num(_ value: Int) -> RuleJSON { .number(Double(value)) }
    static func opt(_ value: String?) -> RuleJSON { value.map { .string($0) } ?? .null }
    /// Ids as a set: sorted, as the cases write sets.
    static func ids(_ values: some Collection<String>) -> RuleJSON { .array(values.sorted().map { .string($0) }) }
    /// Ids in their order.
    static func list(_ values: [String]) -> RuleJSON { .array(values.map { .string($0) }) }
}
