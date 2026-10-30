import Foundation

/// `{"subsonic-response": {...}}`
struct ResponseEnvelope<Payload: Decodable>: Decodable {
    let body: ResponseBody<Payload>

    private enum CodingKeys: String, CodingKey {
        case body = "subsonic-response"
    }
}

/// The inner object: either `status: ok` with the payload alongside, or `status: failed` with an
/// optional `error`. The payload is read from the request's element path, passed in `userInfo`.
enum ResponseBody<Payload: Decodable>: Decodable {
    case ok(Payload)
    case failed(code: SubsonicErrorCode, message: String?)

    private enum CodingKeys: String, CodingKey {
        case status, error
    }

    private struct ErrorBody: Decodable {
        let code: SubsonicErrorCode
        let message: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .status) == "ok" else {
            let error = try? container.decodeIfPresent(ErrorBody.self, forKey: .error)
            self = .failed(code: error?.code ?? .generic, message: error?.message)
            return
        }
        let path = decoder.userInfo[.subsonicElementPath] as? [String] ?? []
        self = try .ok(ElementDecoder.decode(Payload.self, at: path, from: decoder))
    }
}
