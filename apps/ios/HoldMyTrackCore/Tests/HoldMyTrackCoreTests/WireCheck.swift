import Foundation

enum WireMode { case response, request }

/// Holds a Decodable type to the schema it decodes or encodes by running its own init(from:)
/// against a decoder that answers from the schema instead of from JSON: each key the type asks
/// for is looked up there, `decode` read as a field the type needs and `decodeIfPresent` as one
/// it can do without. A request type is checked the same way, since its synthesized Encodable
/// sends what its Decodable reads. Each disagreement lands in problems and every type reached in
/// seen; past one, the rest of that value is read with no schema, so one run reports them all.
final class WireCheck {
    var problems: [String] = []
    var seen: Set<String> = []

    func check<T: Decodable>(_ type: T.Type, _ schema: Schema, at path: String, _ mode: WireMode) {
        do {
            _ = try value(T.self, schema, at: path, mode)
        } catch {
            problems.append("\(path): \(error)")
        }
    }

    func value<T: Decodable>(_ type: T.Type, _ schema: Schema?, at path: String, _ mode: WireMode) throws -> T {
        let decoder = SchemaDecoder(check: self, schema: schema, path: path, mode: mode)
        let value = try T(from: decoder)
        if let fields = decoder.fields {
            seen.insert(String(describing: T.self))
            if mode == .request, let schema {
                let required = Set(schema["required"] as? [String] ?? [])
                for name in required.subtracting(fields).sorted() {
                    problems.append("\(path): the contract requires \(name), which \(T.self) doesn't send")
                }
            }
        }
        return value
    }

    func problem(_ text: String) { problems.append(text) }
}

private final class SchemaDecoder: Decoder {
    let check: WireCheck
    /// nil once a disagreement was recorded above: everything below is answered unchecked.
    let schema: Schema?
    let path: String
    let mode: WireMode
    /// The keys a struct asked for; nil until it asks, and for anything but a struct.
    var fields: Set<String>?

    init(check: WireCheck, schema: Schema?, path: String, mode: WireMode) {
        self.check = check
        self.schema = schema
        self.path = path
        self.mode = mode
    }

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    var type: String { schema?["type"] as? String ?? "nothing" }

    func container<Key: CodingKey>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        // Dictionary<String, V> decodes through a keyed container of its own private key type.
        let isMap = String(describing: Key.self).contains("DictionaryCodingKey")
        var schema = schema
        if let given = schema {
            let values = given["additionalProperties"] as? Schema
            if type != "object" {
                check.problem("\(path) is an object, the contract a \(type)")
                schema = nil
            } else if isMap, values == nil {
                check.problem("\(path) is a map, the contract has no additionalProperties")
                schema = nil
            }
        }
        if !isMap { fields = fields ?? [] }
        return KeyedDecodingContainer(Keyed<Key>(decoder: self, schema: schema, isMap: isMap))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        if schema != nil, type != "array" {
            check.problem("\(path) is a list, the contract a \(type)")
            return Unkeyed(decoder: self, items: nil, count: 0)
        }
        return Unkeyed(decoder: self, items: schema?["items"] as? Schema, count: schema == nil ? 0 : 1)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { Single(decoder: self) }

    /// A scalar of the Swift type named want, which the contract types as one of types.
    func scalar<T>(_ want: String, _ types: Set<String>, _ fallback: T) -> T {
        if schema != nil, !types.contains(type) { check.problem("\(path) is \(want), the contract a \(type)") }
        return fallback
    }

    func string() -> String {
        let value = scalar("a string", ["string"], "")
        // A raw-value enum decodes only from one of its cases.
        return (schema?["enum"] as? [Any])?.first.map { "\($0)" } ?? value
    }

    func child<T: Decodable>(_ type: T.Type, _ schema: Schema?, at path: String) throws -> T {
        try check.value(T.self, self.schema == nil ? nil : schema, at: path, mode)
    }
}

private struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: SchemaDecoder
    let schema: Schema?
    let isMap: Bool

    var codingPath: [any CodingKey] { [] }
    var properties: [String: Schema] { schema?["properties"] as? [String: Schema] ?? [:] }
    var required: Set<String> { Set(schema?["required"] as? [String] ?? []) }

    var allKeys: [Key] {
        guard schema != nil else { return [] }
        return isMap ? [Key(stringValue: "key")].compactMap { $0 } : properties.keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func field<T: Decodable>(_ type: T.Type, _ key: Key, optional: Bool) throws -> T {
        if isMap { return try decoder.child(T.self, schema?["additionalProperties"] as? Schema, at: "\(decoder.path){}") }
        let name = key.stringValue
        let at = "\(decoder.path).\(name)"
        decoder.fields?.insert(name)
        guard schema != nil else { return try decoder.child(T.self, nil, at: at) }
        guard let property = properties[name] else {
            decoder.check.problem("\(at) is not in the contract")
            return try decoder.check.value(T.self, nil, at: at, decoder.mode)
        }
        switch decoder.mode {
        case .response where !optional:
            if !required.contains(name) { decoder.check.problem("\(at): the contract doesn't require it, so make it optional") }
            if property["nullable"] as? Bool == true { decoder.check.problem("\(at): the contract says it can be null, so make it optional") }
        case .request where optional && required.contains(name):
            decoder.check.problem("\(at): the contract requires it, so it can't be left out")
        default:
            break
        }
        return try decoder.child(T.self, property, at: at)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try field(T.self, key, optional: false) }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { try field(T.self, key, optional: true) }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try field(type, key, optional: false) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try field(type, key, optional: false) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try field(type, key, optional: false) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try field(type, key, optional: false) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try field(type, key, optional: false) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try field(type, key, optional: false) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try field(type, key, optional: false) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try field(type, key, optional: false) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try field(type, key, optional: false) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try field(type, key, optional: false) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try field(type, key, optional: false) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try field(type, key, optional: false) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try field(type, key, optional: false) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try field(type, key, optional: false) }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try field(type, key, optional: true) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try field(type, key, optional: true) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw ContractError("\(decoder.path): nested containers aren't checked; give \(key.stringValue) a type of its own")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw ContractError("\(decoder.path): nested containers aren't checked; give \(key.stringValue) a type of its own")
    }

    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: Key) throws -> any Decoder { decoder }
}

/// A list of one element, read against the contract's items.
private struct Unkeyed: UnkeyedDecodingContainer {
    let decoder: SchemaDecoder
    let items: Schema?
    let count: Int?
    var currentIndex = 0

    init(decoder: SchemaDecoder, items: Schema?, count: Int) {
        self.decoder = decoder
        self.items = items
        self.count = count
    }

    var codingPath: [any CodingKey] { [] }
    var isAtEnd: Bool { currentIndex >= (count ?? 0) }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        return try decoder.child(T.self, items, at: "\(decoder.path)[]")
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try decode(Wrapped<Bool>.self).value }
    mutating func decode(_ type: String.Type) throws -> String { try decode(Wrapped<String>.self).value }
    mutating func decode(_ type: Double.Type) throws -> Double { try decode(Wrapped<Double>.self).value }
    mutating func decode(_ type: Float.Type) throws -> Float { try decode(Wrapped<Float>.self).value }
    mutating func decode(_ type: Int.Type) throws -> Int { try decode(Wrapped<Int>.self).value }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try decode(Wrapped<Int8>.self).value }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try decode(Wrapped<Int16>.self).value }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try decode(Wrapped<Int32>.self).value }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try decode(Wrapped<Int64>.self).value }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try decode(Wrapped<UInt>.self).value }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decode(Wrapped<UInt8>.self).value }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decode(Wrapped<UInt16>.self).value }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decode(Wrapped<UInt32>.self).value }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decode(Wrapped<UInt64>.self).value }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        throw ContractError("\(decoder.path): nested containers aren't checked")
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw ContractError("\(decoder.path): nested containers aren't checked")
    }

    mutating func superDecoder() throws -> any Decoder { decoder }
}

/// A scalar decoded through the generic path, so it gets its own decoder over the items schema.
private struct Wrapped<T: Decodable>: Decodable {
    let value: T
    init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(T.self) }
}

private struct Single: SingleValueDecodingContainer {
    let decoder: SchemaDecoder

    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool { decoder.scalar("a boolean", ["boolean"], false) }
    func decode(_ type: String.Type) throws -> String { decoder.string() }
    func decode(_ type: Double.Type) throws -> Double { decoder.scalar("a number", ["number", "integer"], 0) }
    func decode(_ type: Float.Type) throws -> Float { decoder.scalar("a number", ["number", "integer"], 0) }
    func decode(_ type: Int.Type) throws -> Int { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: Int8.Type) throws -> Int8 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: Int16.Type) throws -> Int16 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: Int32.Type) throws -> Int32 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: Int64.Type) throws -> Int64 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: UInt.Type) throws -> UInt { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { decoder.scalar("an integer", ["integer"], 0) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { decoder.scalar("an integer", ["integer"], 0) }

    // Through a decoder of its own, so the type is recorded as seen: Optional<X> reads X here.
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.child(T.self, decoder.schema, at: decoder.path) }
}
