import Foundation

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

extension CodingUserInfoKey {
    // swiftlint:disable:next force_unwrapping
    static let subsonicElementPath = CodingUserInfoKey(rawValue: "subsonicElementPath")!
}

/// A response type with a natural "nothing here" value, used when the server omits the element
/// (an empty list, or no saved play queue).
protocol AbsentElementDefault {
    static var absentElementDefault: Self { get }
}

extension Array: AbsentElementDefault {
    static var absentElementDefault: Self {
        []
    }
}

extension Optional: AbsentElementDefault {
    static var absentElementDefault: Self {
        nil
    }
}

/// Lists decode with `OneOrMany` semantics wherever they appear in an element path.
protocol LenientList {
    static func decodeLeniently(
        from container: KeyedDecodingContainer<AnyCodingKey>,
        forKey key: AnyCodingKey
    ) throws -> Self
}

extension Array: LenientList where Element: Decodable {
    static func decodeLeniently(
        from container: KeyedDecodingContainer<AnyCodingKey>,
        forKey key: AnyCodingKey
    ) throws -> Self {
        try container.decode(OneOrMany<Element>.self, forKey: key).wrappedValue
    }
}

/// Decodes the value at a request's element path, for example `["albumList2", "album"]`.
enum ElementDecoder {
    static func decode<Value: Decodable>(_: Value.Type, at path: [String], from decoder: any Decoder) throws -> Value {
        guard let last = path.last else { return try Value(from: decoder) }

        var container = try decoder.container(keyedBy: AnyCodingKey.self)
        for name in path.dropLast() {
            let key = AnyCodingKey(name)
            guard container.contains(key), try !container.decodeNil(forKey: key) else {
                return try absent(Value.self, path: path, decoder: decoder)
            }
            container = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        }

        let key = AnyCodingKey(last)
        if let list = Value.self as? any LenientList.Type {
            return try cast(list.decodeLeniently(from: container, forKey: key), path: path, decoder: decoder)
        }
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return try absent(Value.self, path: path, decoder: decoder)
        }
        return try container.decode(Value.self, forKey: key)
    }

    private static func absent<Value>(_: Value.Type, path: [String], decoder: any Decoder) throws -> Value {
        guard let defaultType = Value.self as? any AbsentElementDefault.Type else {
            throw DecodingError.keyNotFound(
                AnyCodingKey(path.joined(separator: ".")),
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Response has no \(path.joined(separator: "."))"
                )
            )
        }
        return try cast(defaultType.absentElementDefault, path: path, decoder: decoder)
    }

    private static func cast<Value>(_ value: Any, path: [String], decoder: any Decoder) throws -> Value {
        guard let typed = value as? Value else {
            throw DecodingError.typeMismatch(
                Value.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unexpected type at \(path)")
            )
        }
        return typed
    }
}
