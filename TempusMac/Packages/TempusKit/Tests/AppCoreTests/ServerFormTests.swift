@testable import AppCore
import Foundation
import Persistence
import SecureStorage
import SubsonicAPI
import Testing

struct ServerFormTests {
    @Test
    func `a complete form validates and normalises the address`() throws {
        let server = try TestData.form(address: "  HTTPS://Music.Example.com/ ").validated().get()
        #expect(server.address.url.absoluteString == "https://music.example.com")
        #expect(server.localAddress == nil)
        #expect(server.customHeaders == "")
    }

    @Test(arguments: [ServerForm.Field.name, .username, .password, .address])
    func `empty required fields are mandatory`(field: ServerForm.Field) {
        var form = TestData.form()
        switch field {
        case .name: form.name = "   "
        case .username: form.username = "   "
        case .password: form.password = ""
        default: form.address = "   "
        }
        #expect(form.validated() == .failure(ServerForm.Issue(field: field, message: "Mandatory field")))
    }

    @Test
    func `checks fields in upstream's order and reports only the first problem`() {
        let form = ServerForm()
        #expect(form.validated() == .failure(ServerForm.Issue(field: .name, message: "Mandatory field")))
    }

    @Test(arguments: ["music.example.com", "ftp://music.example.com", "https://", "https://a b.com"])
    func `an address that isn't an http URL with a host is not valid`(address: String) {
        let form = TestData.form(address: address)
        #expect(form.validated() == .failure(ServerForm.Issue(field: .address, message: "URL not valid")))
    }

    @Test
    func `the local address is checked only when switched on`() throws {
        var form = TestData.form()
        form.localAddress = "not a url"
        #expect(try form.validated().get().localAddress == nil)

        form.usesLocalAddress = true
        #expect(form.validated() == .failure(ServerForm.Issue(field: .localAddress, message: "URL not valid")))
        form.localAddress = ""
        #expect(form.validated() == .failure(ServerForm.Issue(field: .localAddress, message: "Mandatory field")))
        form.localAddress = "http://192.168.1.10:4533"
        #expect(try form.validated().get().localAddress?.url.absoluteString == "http://192.168.1.10:4533")
    }

    @Test
    func `custom headers report the first bad line`() throws {
        var form = TestData.form()
        form.usesCustomHeaders = true
        form.customHeaders = "CF-Access-Client-Id: abc\n# comment\nnot a header\nHost: x"
        #expect(form.validated() == .failure(ServerForm.Issue(
            field: .customHeaders,
            message: "Invalid header on line 3. Use Name: Value"
        )))

        form.customHeaders = "CF-Access-Client-Id: abc"
        #expect(try form.validated().get().customHeaders == "CF-Access-Client-Id: abc")
        form.usesCustomHeaders = false
        #expect(try form.validated().get().customHeaders == "")
    }

    @Test
    func `a client certificate is required once switched on, and kept only then`() throws {
        var form = TestData.form()
        form.usesClientCertificate = true
        #expect(form.validated() == .failure(ServerForm.Issue(field: .clientCertificate, message: "Mandatory field")))

        let file = CertificateFile(data: Data([1, 2, 3]), passphrase: "pw", subject: "Me")
        form.clientCertificate = file
        #expect(try form.validated().get().clientCertificate == file)
        form.usesClientCertificate = false
        #expect(try form.validated().get().clientCertificate == nil)
    }

    @Test
    func `warns about every address sent over plain http`() {
        var form = TestData.form(address: "http://music.example.com")
        form.usesLocalAddress = true
        form.localAddress = "http://192.168.1.10"
        #expect(form.warnings == [.cleartextAddress, .cleartextLocalAddress])

        form.address = "https://music.example.com"
        form.usesLocalAddress = false
        #expect(form.warnings.isEmpty)
        #expect(!ServerForm.Warning.cleartextLocalAddress.message.isEmpty)
    }

    @Test
    func `editing starts from the saved server and its secrets`() throws {
        let profile = try ServerProfile(
            id: "1", name: "Home", username: "alice", address: ServerAddress(TestData.address),
            localAddress: ServerAddress("http://10.0.0.2"), usesPlaintextPassword: true, createdAt: .now
        )
        let secrets = ServerSecrets(
            password: "pw", customHeaders: "X-Token: 1", origins: [],
            clientCertificate: Data([9]), clientCertificatePassphrase: "pass"
        )

        let form = ServerForm(editing: profile, secrets: secrets, certificateSubject: "Me")

        #expect(form.name == "Home" && form.username == "alice" && form.password == "pw")
        #expect(form.address == TestData.address)
        #expect(form.usesLocalAddress && form.localAddress == "http://10.0.0.2")
        #expect(form.usesPlaintextPassword)
        #expect(form.usesCustomHeaders && form.customHeaders == "X-Token: 1")
        #expect(form.usesClientCertificate)
        #expect(form.clientCertificate == CertificateFile(data: Data([9]), passphrase: "pass", subject: "Me"))
    }

    @Test
    func `warns when a plaintext password would travel over http`() {
        var form = TestData.form(address: "http://music.example.com")
        form.usesPlaintextPassword = true
        #expect(form.warnings.contains(.plaintextPasswordOverHTTP))
        form.address = "https://music.example.com"
        #expect(!form.warnings.contains(.plaintextPasswordOverHTTP))
    }
}
