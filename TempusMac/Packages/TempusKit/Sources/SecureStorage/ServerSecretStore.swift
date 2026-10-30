import Foundation

/// What upstream kept "the same way as your password": the password itself and the raw
/// custom-header text (which may hold proxy service tokens).
public struct ServerSecrets: Codable, Sendable, Equatable {
    public let password: String
    /// One `Name: Value` per line, as typed. Parse with `SubsonicAPI.CustomHeaders`.
    public let customHeaders: String

    public init(password: String, customHeaders: String = "") {
        self.password = password
        self.customHeaders = customHeaders
    }
}

extension ServerSecrets: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ServerSecrets(password: <redacted>, customHeaders: <redacted>)"
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

    public func secrets(forServer id: String) throws(SecretStoreError) -> ServerSecrets? {
        guard let data = try store.data(for: key(id)) else { return nil }
        do {
            return try JSONDecoder().decode(ServerSecrets.self, from: data)
        } catch {
            throw .decodingFailed
        }
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
