@testable import AppCore
import Foundation
import Testing

struct ClientCertificateImportTests {
    /// A throwaway self-signed identity made with OpenSSL 3 (AES-256, PBKDF2), passphrase `tempus-test`.
    static func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "test-client",
            withExtension: "p12",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    @Test
    func `imports the identity in memory and names its subject`() throws {
        let imported = try ClientCertificateImporter.importIdentity(pkcs12: Self.fixture(), passphrase: "tempus-test")
        #expect(imported.subject == "Tempus Test Client")
        #expect(imported.certificate.chain.isEmpty == false)
    }

    @Test
    func `a wrong passphrase is reported as such`() {
        #expect(throws: ClientCertificateImportError.wrongPassphrase) {
            try ClientCertificateImporter.importIdentity(pkcs12: Self.fixture(), passphrase: "nope")
        }
    }

    @Test
    func `data that is not PKCS#12 is unreadable`() {
        #expect(throws: ClientCertificateImportError.unreadable) {
            try ClientCertificateImporter.importIdentity(pkcs12: Data("hello".utf8), passphrase: "")
        }
    }

    @Test
    func `errors have messages`() {
        #expect(!ClientCertificateImportError.wrongPassphrase.userMessage.isEmpty)
        #expect(!ClientCertificateImportError.unreadable.userMessage.isEmpty)
        #expect(!ClientCertificateImportError.noIdentity.userMessage.isEmpty)
    }
}
