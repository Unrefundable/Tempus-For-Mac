import Foundation

// Subsonic servers disagree on JSON details. These wrappers decode as leniently as upstream
// Tempus does with Gson (RetrofitClient, EmptyDateTypeAdapter, BookmarksDeserializer): see ADR 0002.

/// Parses the date forms servers send: ISO 8601 with or without fractional seconds (any number
/// of digits) and with `Z`, an offset, or no zone at all (read as UTC). Anything else is `nil`.
enum SubsonicDate {
    static func parse(_ text: String) -> Date? {
        // A local: `Regex` is not Sendable, so it can't be a shared static. Literals are compiled
        // at build time, so creating one per call is cheap.
        let pattern = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/
        guard let match = text.wholeMatch(of: pattern) else { return nil }
        let zone = match.3.map { String($0).replacing(":", with: "") } ?? "Z"
        guard let whole = try? Date.ISO8601FormatStyle().parse(String(match.1) + zone) else { return nil }
        let fraction = match.2.flatMap { Double("0" + $0) } ?? 0
        return whole.addingTimeInterval(fraction)
    }
}

/// An identifier that some servers send as a JSON number.
@propertyWrapper
public struct LenientString: Decodable, Sendable, Hashable {
    public var wrappedValue: String

    public init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else if let number = try? container.decode(Int64.self) {
            wrappedValue = String(number)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer id")
            )
        }
    }
}

/// An optional identifier that may be a number, missing, or of an unexpected type (`nil`).
@propertyWrapper
public struct LenientOptionalString: Decodable, Sendable, Hashable {
    public var wrappedValue: String?

    public init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        wrappedValue = try? LenientString(from: decoder).wrappedValue
    }
}

/// A date that is `nil` when missing, empty or unparseable, instead of failing the response.
@propertyWrapper
public struct LenientDate: Decodable, Sendable, Hashable {
    public var wrappedValue: Date?

    public init(wrappedValue: Date?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let text = try? decoder.singleValueContainer().decode(String.self)
        wrappedValue = text.flatMap(SubsonicDate.parse)
    }
}

/// A list that some servers send as a single object when it has one element, or omit when empty.
@propertyWrapper
public struct OneOrMany<Element: Decodable>: Decodable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    /// Tries a list first, then a single element. If both fail, the list's error is the one
    /// reported, since it usually points at the element that was actually wrong.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = []
            return
        }
        do {
            wrappedValue = try container.decode([Element].self)
        } catch let listError {
            guard let single = try? container.decode(Element.self) else { throw listError }
            wrappedValue = [single]
        }
    }
}

extension OneOrMany: Sendable where Element: Sendable {}
extension OneOrMany: Equatable where Element: Equatable {}
extension OneOrMany: Hashable where Element: Hashable {}

/// Missing keys reach these overloads instead of failing, which is what makes the wrappers optional.
public extension KeyedDecodingContainer {
    func decode(_: LenientOptionalString.Type, forKey key: Key) throws -> LenientOptionalString {
        let value = try? decodeIfPresent(LenientString.self, forKey: key)
        return LenientOptionalString(wrappedValue: value?.wrappedValue)
    }

    func decode(_: LenientDate.Type, forKey key: Key) throws -> LenientDate {
        let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil
        return LenientDate(wrappedValue: text.flatMap(SubsonicDate.parse))
    }

    func decode<Element>(_: OneOrMany<Element>.Type, forKey key: Key) throws -> OneOrMany<Element> {
        guard contains(key) else { return OneOrMany(wrappedValue: []) }
        return try OneOrMany(from: superDecoder(forKey: key))
    }
}
