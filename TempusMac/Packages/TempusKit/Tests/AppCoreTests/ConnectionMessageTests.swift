@testable import AppCore
import Foundation
import SubsonicAPI
import Testing

struct ConnectionMessageTests {
    @Test
    func `wrong credentials say so`() {
        let message = SubsonicError.server(code: .wrongCredentials, message: "Wrong username or password").userMessage
        #expect(message == "Wrong username or password.")
    }

    @Test
    func `token auth refusal suggests sending the password in plain text`() {
        let message = SubsonicError.server(code: .tokenAuthNotSupported, message: nil).userMessage
        #expect(message.contains("Plaintext password"))
    }

    @Test(arguments: [401, 403])
    func `a refusal from a proxy points at custom headers`(status: Int) {
        let message = SubsonicError.httpStatus(status).userMessage
        #expect(message.contains("HTTP \(status)"))
        #expect(message.contains("custom headers"))
    }

    @Test
    func `a 404 or an unreadable body means it is not a Subsonic server`() {
        #expect(SubsonicError.httpStatus(404).userMessage.contains("doesn't look like a Subsonic server"))
        #expect(SubsonicError.decoding("keyNotFound").userMessage.contains("doesn't look like a Subsonic server"))
    }

    @Test
    func `server errors show the server's own message, shortened`() {
        let long = String(repeating: "x", count: 400)
        let message = SubsonicError.server(code: .generic, message: long).userMessage
        #expect(message.hasPrefix("The server reported an error: "))
        #expect(message.count < 250)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, "offline"),
        (.cannotFindHost, "Couldn't find"),
        (.cannotConnectToHost, "isn't answering"),
        (.timedOut, "too long"),
        (.serverCertificateUntrusted, "certificate"),
        (.clientCertificateRequired, "client certificate"),
        (.appTransportSecurityRequiresSecureConnection, "https"),
    ])
    func `transport errors have plain explanations`(code: URLError.Code, expected: String) {
        #expect(SubsonicError.transport(code).userMessage.contains(expected))
    }

    @Test
    func `server text loses control characters and line breaks before it is shown`() {
        let message = SubsonicError.server(code: .generic, message: "Bad\nthing\u{0007}\r\nhere").userMessage
        #expect(message == "The server reported an error: Bad thing here")
    }
}
