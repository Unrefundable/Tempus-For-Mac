import Foundation
@testable import SubsonicAPI
import Testing

private struct Item: Decodable, Equatable {
    let number: Int
}

private struct Probe: Decodable {
    @LenientString var id: String
    @LenientOptionalString var parent: String?
    @LenientDate var created: Date?
    @OneOrMany var items: [Item]
}

private func probe(_ json: String) throws -> Probe {
    try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
}

@Suite("Lenient decoding of server quirks")
struct LenientDecodingTests {
    static let reference = Date(timeIntervalSince1970: 1_709_634_030)

    @Test("Dates parse in every form servers send", arguments: [
        ("2024-03-05T10:20:30Z", 0.0),
        ("2024-03-05T10:20:30.123Z", 0.123),
        ("2024-03-05T10:20:30.123456789Z", 0.123456789),
        ("2024-03-05T10:20:30", 0.0),
        ("2024-03-05T12:20:30+02:00", 0.0),
    ])
    func datesParse(text: String, fraction: Double) throws {
        let date = try #require(try probe(#"{"id":"1","created":"\#(text)"}"#).created)

        #expect(abs(date.timeIntervalSince1970 - (Self.reference.timeIntervalSince1970 + fraction)) < 0.001)
    }

    @Test("Empty, malformed, non-string or missing dates become nil", arguments: [
        #"{"id":"1","created":""}"#,
        #"{"id":"1","created":"yesterday"}"#,
        #"{"id":"1","created":12345}"#,
        #"{"id":"1"}"#,
    ])
    func badDatesBecomeNil(json: String) throws {
        #expect(try probe(json).created == nil)
    }

    @Test("Ids accept strings and numbers")
    func idsAcceptNumbers() throws {
        #expect(try probe(#"{"id":"al-1"}"#).id == "al-1")
        #expect(try probe(#"{"id":42}"#).id == "42")
        #expect(try probe(#"{"id":"1","parent":7}"#).parent == "7")
        #expect(try probe(#"{"id":"1"}"#).parent == nil)
    }

    @Test("A missing id fails decoding")
    func missingIDFails() {
        #expect(throws: DecodingError.self) { try probe(#"{"parent":"1"}"#) }
    }

    @Test("Lists accept an array, a single object or nothing")
    func oneOrMany() throws {
        #expect(try probe(#"{"id":"1","items":[{"number":1},{"number":2}]}"#).items == [
            Item(number: 1),
            Item(number: 2),
        ])
        #expect(try probe(#"{"id":"1","items":{"number":3}}"#).items == [Item(number: 3)])
        #expect(try probe(#"{"id":"1"}"#).items.isEmpty)
    }
}
