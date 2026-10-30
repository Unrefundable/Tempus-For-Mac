import Foundation
import Security
import SubsonicAPI

public enum ClientCertificateImportError: Error, Sendable, Equatable {
    case wrongPassphrase
    /// Not a PKCS#12 file, or one macOS can't read.
    case unreadable
    /// The file holds certificates but no private key.
    case noIdentity

    public var userMessage: String {
        switch self {
        case .wrongPassphrase: "The passphrase for this certificate is wrong."
        case .unreadable: "This file isn't a certificate Tempus can read. Choose a .p12 or .pfx file."
        case .noIdentity: "This file has no private key, so it can't be used as a client certificate."
        }
    }
}

/// A client identity read from a `.p12` file, with the name to show for it.
public struct ImportedCertificate: Sendable {
    public let certificate: ClientCertificate
    /// The certificate's subject, for example its common name.
    public let subject: String
}

/// Reads `.p12` client certificates for mutual TLS. The identity stays in memory: the file's bytes
/// and passphrase are what the Keychain keeps (`ServerSecrets`), and they are imported again for
/// each session.
public enum ClientCertificateImporter {
    /// The same import, off the main actor: PKCS#12 key derivation is slow by design, and a
    /// crafted file can make it slower.
    @concurrent
    public static func importIdentityInBackground(
        pkcs12 data: Data,
        passphrase: String
    ) async throws(ClientCertificateImportError) -> ImportedCertificate {
        try importIdentity(pkcs12: data, passphrase: passphrase)
    }

    public static func importIdentity(
        pkcs12 data: Data,
        passphrase: String
    ) throws(ClientCertificateImportError) -> ImportedCertificate {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            // Without this, macOS also adds the identity to the login keychain.
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure, errSecPassphraseRequired:
            throw .wrongPassphrase
        default:
            throw .unreadable
        }
        guard let first = (items as? [[String: Any]])?.first,
              let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID()
        else { throw .noIdentity }
        // The type was checked above, so the cast can't fail.
        let identity = identityValue as! SecIdentity // swiftlint:disable:this force_cast
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return ImportedCertificate(
            certificate: ClientCertificate(identity: identity, chain: chain),
            subject: subject(of: identity, chain: chain)
        )
    }

    private static func subject(of identity: SecIdentity, chain: [SecCertificate]) -> String {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let summary = (certificate ?? chain.first).flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return summary ?? "Client certificate"
    }
}
