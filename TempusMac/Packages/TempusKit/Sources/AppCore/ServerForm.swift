import Foundation
import Persistence
import SecureStorage
import SubsonicAPI

/// A `.p12` client certificate picked in the server editor.
public struct CertificateFile: Sendable, Equatable {
    public let data: Data
    public let passphrase: String
    /// Shown in the editor so the user can tell which certificate is attached.
    public let subject: String

    public init(data: Data, passphrase: String, subject: String) {
        self.data = data
        self.passphrase = passphrase
        self.subject = subject
    }
}

/// A server form that passed validation, ready to test or save.
public struct ValidServer: Sendable, Equatable {
    public let name: String
    public let username: String
    public let password: String
    public let address: ServerAddress
    public let localAddress: ServerAddress?
    public let usesPlaintextPassword: Bool
    /// Raw `Name: Value` lines, empty when switched off.
    public let customHeaders: String
    public let clientCertificate: CertificateFile?
}

/// The server editor's fields, as upstream's `LoginServerFragment`: optional parts sit behind
/// switches and are dropped when switched off.
public struct ServerForm: Sendable, Equatable {
    public enum Field: Sendable, Hashable {
        case name, username, password, address, localAddress, customHeaders, clientCertificate
    }

    /// The first problem found, attached to the field to show it on.
    public struct Issue: Error, Sendable, Equatable {
        public let field: Field
        public let message: String
    }

    public enum Warning: Sendable, Equatable {
        case cleartextAddress, cleartextLocalAddress, plaintextPasswordOverHTTP

        public var message: String {
            switch self {
            case .cleartextAddress:
                "This address uses http, so your password and headers travel unencrypted. Use https if you can."
            case .cleartextLocalAddress:
                "The local address uses http. Your password and headers travel unencrypted, and on another "
                    + "network a device that takes over this address would receive them."
            case .plaintextPasswordOverHTTP:
                "Plaintext password is on and an address uses http, so your actual password is readable "
                    + "by anyone on the network."
            }
        }
    }

    static let mandatory = "Mandatory field"
    static let invalidURL = "URL not valid"

    public var name = ""
    public var username = ""
    public var password = ""
    public var address = ""
    public var usesPlaintextPassword = false
    public var usesLocalAddress = false
    public var localAddress = ""
    public var usesCustomHeaders = false
    public var customHeaders = ""
    public var usesClientCertificate = false
    public var clientCertificate: CertificateFile?

    public init() {}

    /// Starts from a saved server and its Keychain secrets.
    public init(editing profile: ServerProfile, secrets: ServerSecrets?, certificateSubject: String?) {
        name = profile.name
        username = profile.username
        password = secrets?.password ?? ""
        address = profile.address.url.absoluteString
        usesPlaintextPassword = profile.usesPlaintextPassword
        usesLocalAddress = profile.localAddress != nil
        localAddress = profile.localAddress?.url.absoluteString ?? ""
        customHeaders = secrets?.customHeaders ?? ""
        usesCustomHeaders = !customHeaders.isEmpty
        if let data = secrets?.clientCertificate {
            usesClientCertificate = true
            clientCertificate = CertificateFile(
                data: data,
                passphrase: secrets?.clientCertificatePassphrase ?? "",
                subject: certificateSubject ?? "Client certificate"
            )
        }
    }

    /// Checks fields in upstream's order and stops at the first problem, as upstream does.
    public func validated() -> Result<ValidServer, Issue> {
        Result { () throws(Issue) in try validServer() }
    }

    /// Addresses that would send credentials unencrypted. Only addresses that parse are checked.
    public var warnings: [Warning] {
        var warnings: [Warning] = []
        if (try? ServerAddress(address))?.isCleartext == true {
            warnings.append(.cleartextAddress)
        }
        if usesLocalAddress, (try? ServerAddress(localAddress))?.isCleartext == true {
            warnings.append(.cleartextLocalAddress)
        }
        if usesPlaintextPassword, !warnings.isEmpty {
            warnings.append(.plaintextPasswordOverHTTP)
        }
        return warnings
    }

    private func validServer() throws(Issue) -> ValidServer {
        let name = try required(name, .name)
        let username = try required(username, .username)
        guard !password.isEmpty else { throw Issue(field: .password, message: Self.mandatory) }
        let address = try url(address, .address)
        let localAddress = usesLocalAddress ? try url(localAddress, .localAddress) : nil
        if usesCustomHeaders, let line = CustomHeaders.invalidLineNumbers(in: customHeaders).first {
            throw Issue(field: .customHeaders, message: "Invalid header on line \(line). Use Name: Value")
        }
        if usesClientCertificate, clientCertificate == nil {
            throw Issue(field: .clientCertificate, message: Self.mandatory)
        }
        return ValidServer(
            name: name,
            username: username,
            password: password,
            address: address,
            localAddress: localAddress,
            usesPlaintextPassword: usesPlaintextPassword,
            customHeaders: usesCustomHeaders ? customHeaders.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            clientCertificate: usesClientCertificate ? clientCertificate : nil
        )
    }

    private func required(_ text: String, _ field: Field) throws(Issue) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Issue(field: field, message: Self.mandatory) }
        return trimmed
    }

    private func url(_ text: String, _ field: Field) throws(Issue) -> ServerAddress {
        let trimmed = try required(text, field)
        do {
            return try ServerAddress(trimmed)
        } catch {
            throw Issue(field: field, message: Self.invalidURL)
        }
    }
}

// Never print the password, header values or certificate passphrase.

extension CertificateFile: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CertificateFile(\(subject), passphrase: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

extension ValidServer: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ValidServer(\(name), \(username)@\(address.url.absoluteString), secrets: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

extension ServerForm: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ServerForm(\(name), \(username)@\(address), secrets: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
