import Foundation

/// What upstream kept "the same way as your password": the password itself, the raw
/// custom-header text (which may hold proxy service tokens) and the mTLS client identity, bound
/// to the server origins they were entered for.
public struct ServerSecrets: Codable, Sendable, Equatable {
    public let password: String
    /// One `Name: Value` per line, as typed. Parse with `SubsonicAPI.CustomHeaders`.
    public let customHeaders: String
    /// `scheme://host:port` of each address these secrets may be sent to (public and local),
    /// as `SubsonicAPI.ServerAddress.origin` writes them.
    public let origins: Set<String>
    /// A PKCS#12 (`.p12`) client identity for servers behind mutual TLS, as imported. Optional,
    /// so secrets saved before certificates were supported still decode.
    public let clientCertificate: Data?
    public let clientCertificatePassphrase: String?

    public init(
        password: String,
        customHeaders: String = "",
        origins: Set<String>,
        clientCertificate: Data? = nil,
        clientCertificatePassphrase: String? = nil
    ) {
        self.password = password
        self.customHeaders = customHeaders
        self.origins = origins
        self.clientCertificate = clientCertificate
        self.clientCertificatePassphrase = clientCertificatePassphrase
    }
}

extension ServerSecrets: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let certificate = clientCertificate == nil ? "none" : "<redacted>"
        return "ServerSecrets(password: <redacted>, customHeaders: <redacted>, clientCertificate: \(certificate))"
    }

    public var debugDescription: String {
        description
    }
}

/// One keychain item per server, keyed by the server's id.
public struct ServerSecretStore: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainStore()) {
        self.store = store
    }

    /// The server's secrets, for sending to `origin`. Throws `originChanged` when they were saved
    /// for other addresses (the server's address was edited, or a record was imported), so the
    /// password is asked for again instead of being sent to a new host.
    public func secrets(forServer id: String, origin: String) throws(SecretStoreError) -> ServerSecrets? {
        guard let data = try store.data(for: key(id)) else { return nil }
        let secrets: ServerSecrets
        do {
            secrets = try JSONDecoder().decode(ServerSecrets.self, from: data)
        } catch {
            throw .decodingFailed
        }
        guard secrets.origins.contains(origin) else { throw .originChanged }
        return secrets
    }

    public func save(_ secrets: ServerSecrets, forServer id: String) throws(SecretStoreError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(secrets)
        } catch {
            throw .encodingFailed
        }
        try store.set(data, for: key(id))
    }

    public func remove(forServer id: String) throws(SecretStoreError) {
        try store.removeData(for: key(id))
    }

    private func key(_ id: String) -> String {
        "server.\(id)"
    }
}
