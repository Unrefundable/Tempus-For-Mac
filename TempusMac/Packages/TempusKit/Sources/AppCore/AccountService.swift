import Foundation
import os
import Persistence
import SecureStorage
import SubsonicAPI

public enum AccountError: Error, Sendable, Equatable {
    case connection(SubsonicError)
    case certificate(ClientCertificateImportError)
    /// The saved secrets are missing, or were saved for another address: ask for the password again.
    case passwordNeeded
    /// The Keychain refused to hand over the server's secrets (access denied, or locked).
    case keychainUnavailable
    /// The Keychain or the database couldn't be written.
    case storage

    public var userMessage: String {
        switch self {
        case let .connection(error): error.userMessage
        case let .certificate(error): error.userMessage
        case .passwordNeeded: "Enter the password for this server again in the server editor."
        case .keychainUnavailable:
            "Tempus couldn't read this server's password from the Keychain. If macOS asks for access, allow it, "
                + "then connect again."
        case .storage: "The server couldn't be saved. Check that Tempus can use the Keychain, then try again."
        }
    }
}

/// Sends `ping` with a client. The live one talks to the server; tests stub it.
public struct ConnectionTester: Sendable {
    public let ping: @Sendable (SubsonicClient) async throws(SubsonicError) -> ServerInfo

    public init(ping: @escaping @Sendable (SubsonicClient) async throws(SubsonicError) -> ServerInfo) {
        self.ping = ping
    }

    public static let live = Self { client throws(SubsonicError) in try await client.send(.ping) }
}

/// What a session needs to talk to a server: its profile and its secrets, read from the Keychain.
public struct ServerCredentials: Sendable {
    public let profile: ServerProfile
    let password: String
    let headers: CustomHeaders
    let certificate: ClientCertificate?
    /// Nil without a client certificate.
    public let certificateSubject: String?

    /// A client for one of the server's addresses. The token salt is fresh for each client.
    public func client(at address: ServerAddress) -> SubsonicClient {
        let credential: SubsonicCredential = profile.usesPlaintextPassword
            ? .plaintext(password: password)
            : .tokenized(password: password)
        return SubsonicClient(
            server: address,
            auth: SubsonicAuth(username: profile.username, credential: credential),
            headers: headers,
            clientCertificate: certificate
        )
    }
}

/// Saved servers: the profile in the database, the password, headers and client certificate in the
/// Keychain, bound to the server's addresses.
public struct AccountService: Sendable {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Accounts")

    private let servers: ServerStore
    private let secrets: ServerSecretStore
    private let tester: ConnectionTester
    private let makeID: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        secrets: ServerSecretStore,
        tester: ConnectionTester = .live,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        servers = ServerStore(database: database)
        self.secrets = secrets
        self.tester = tester
        self.makeID = makeID
        self.now = now
    }

    public func all() async throws(AccountError) -> [ServerProfile] {
        do {
            return try await servers.all()
        } catch {
            Self.logger.error("Couldn't read the saved servers: \(error)")
            throw .storage
        }
    }

    /// Pings the form's public address, then its local one if the public one fails, without saving.
    /// Reports the public address's error when neither answers.
    @discardableResult
    public func test(_ server: ValidServer) async throws(AccountError) -> ServerInfo {
        let credentials = try credentials(for: draftProfile(server), server: server)
        do {
            return try await tester.ping(credentials.client(at: server.address))
        } catch {
            guard let local = server.localAddress, local != server.address,
                  let info = try? await tester.ping(credentials.client(at: local))
            else { throw .connection(error) }
            return info
        }
    }

    /// Saves a new server, or replaces `existing` keeping its id and creation date. Secrets go to the
    /// Keychain first, so a profile is never saved without them; if the profile then can't be
    /// saved, the previous secrets are put back.
    public func save(
        _ server: ValidServer,
        replacing existing: ServerProfile?
    ) async throws(AccountError) -> ServerProfile {
        if let certificate = server.clientCertificate {
            _ = try importCertificate(certificate.data, passphrase: certificate.passphrase)
        }
        let profile = ServerProfile(
            id: existing?.id ?? makeID(),
            name: server.name,
            username: server.username,
            address: server.address,
            localAddress: server.localAddress,
            usesPlaintextPassword: server.usesPlaintextPassword,
            createdAt: existing?.createdAt ?? now()
        )
        let origins = Set([server.address, server.localAddress].compactMap { $0?.origin })
        let previous = existing.flatMap { try? secrets.secrets(forServer: $0.id, origin: $0.address.origin) }
        let stored = ServerSecrets(
            password: server.password,
            customHeaders: server.customHeaders,
            origins: origins,
            clientCertificate: server.clientCertificate?.data,
            clientCertificatePassphrase: server.clientCertificate?.passphrase
        )
        do {
            try secrets.save(stored, forServer: profile.id)
        } catch {
            Self.logger.error("Couldn't save the server's secrets: \(String(describing: error), privacy: .public)")
            throw .storage
        }
        do {
            try await servers.save(profile)
        } catch {
            Self.logger.error("Couldn't save the server: \(error)")
            if let previous {
                try? secrets.save(previous, forServer: profile.id)
            } else {
                try? secrets.remove(forServer: profile.id)
            }
            throw .storage
        }
        return profile
    }

    /// Deletes the server's Keychain secrets, then the server and its stored data. If the secrets
    /// can't be removed the server is kept, so deleting can be retried rather than leave them behind.
    public func delete(_ profile: ServerProfile) async throws(AccountError) {
        do {
            try secrets.remove(forServer: profile.id)
            try await servers.delete(id: profile.id)
        } catch {
            Self.logger.error("Couldn't delete the server: \(String(describing: error), privacy: .public)")
            throw .storage
        }
    }

    /// The server's secrets for its saved public address, with the client certificate imported.
    /// Runs off the main actor: the Keychain can block on a permission prompt, and PKCS#12 import
    /// is slow by design.
    @concurrent
    public func credentials(for profile: ServerProfile) async throws(AccountError) -> ServerCredentials {
        let stored: ServerSecrets?
        do {
            stored = try secrets.secrets(forServer: profile.id, origin: profile.address.origin)
        } catch .originChanged {
            throw .passwordNeeded
        } catch {
            Self.logger.error("Couldn't read the server's secrets: \(String(describing: error), privacy: .public)")
            throw .keychainUnavailable
        }
        guard let stored else { throw .passwordNeeded }
        var imported: ImportedCertificate?
        if let data = stored.clientCertificate {
            imported = try importCertificate(data, passphrase: stored.clientCertificatePassphrase ?? "")
        }
        return ServerCredentials(
            profile: profile,
            password: stored.password,
            headers: CustomHeaders(parsing: stored.customHeaders),
            certificate: imported?.certificate,
            certificateSubject: imported?.subject
        )
    }

    /// The editor's form for a saved server, filled from its secrets when they can be read.
    @concurrent
    public func formForEditing(_ profile: ServerProfile) async -> ServerForm {
        let stored = try? secrets.secrets(forServer: profile.id, origin: profile.address.origin)
        let subject = stored?.clientCertificate.flatMap { data in
            try? ClientCertificateImporter
                .importIdentity(pkcs12: data, passphrase: stored?.clientCertificatePassphrase ?? "").subject
        }
        return ServerForm(editing: profile, secrets: stored, certificateSubject: subject)
    }

    private func credentials(
        for profile: ServerProfile,
        server: ValidServer
    ) throws(AccountError) -> ServerCredentials {
        let imported = try server.clientCertificate.map { file throws(AccountError) in
            try importCertificate(file.data, passphrase: file.passphrase)
        }
        return ServerCredentials(
            profile: profile,
            password: server.password,
            headers: CustomHeaders(parsing: server.customHeaders),
            certificate: imported?.certificate,
            certificateSubject: imported?.subject
        )
    }

    private func draftProfile(_ server: ValidServer) -> ServerProfile {
        ServerProfile(
            id: "draft", name: server.name, username: server.username, address: server.address,
            localAddress: server.localAddress, usesPlaintextPassword: server.usesPlaintextPassword, createdAt: now()
        )
    }

    private func importCertificate(_ data: Data, passphrase: String) throws(AccountError) -> ImportedCertificate {
        do {
            return try ClientCertificateImporter.importIdentity(pkcs12: data, passphrase: passphrase)
        } catch {
            throw .certificate(error)
        }
    }
}

/// Never prints the password, headers or certificate.
extension ServerCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ServerCredentials(\(profile.username)@\(profile.address.url.host() ?? "?"), secrets: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
