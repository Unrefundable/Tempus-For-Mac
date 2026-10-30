@testable import AppCore
import Foundation
import Persistence
import SecureStorage
import Security
import SubsonicAPI
import Synchronization
import Testing

struct AccountServiceTests {
    let database: AppDatabase
    let keychain = MemorySecretStore()
    let pings = PingStub()

    init() throws {
        database = try AppDatabase.inMemory()
    }

    func service(id: String = "new-id") -> AccountService {
        AccountService(
            database: database,
            secrets: ServerSecretStore(store: keychain),
            tester: pings.tester,
            makeID: { id },
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    @Test
    func `saving a new server stores the profile and keychain secrets bound to its origins`() async throws {
        var form = TestData.form()
        form.usesLocalAddress = true
        form.localAddress = "http://192.168.1.10:4533"
        form.usesCustomHeaders = true
        form.customHeaders = "X-Token: abc"

        let profile = try await service().save(TestData.validServer(form), replacing: nil)

        #expect(profile.id == "new-id")
        #expect(try await ServerStore(database: database).all() == [profile])
        let secrets = try ServerSecretStore(store: keychain).secrets(
            forServer: "new-id",
            origin: profile.address.origin
        )
        #expect(secrets?.password == "secret")
        #expect(secrets?.customHeaders == "X-Token: abc")
        #expect(secrets?.origins == ["https://music.example.com:443", "http://192.168.1.10:4533"])
    }

    @Test
    func `updating keeps the id and creation date`() async throws {
        let original = try await service().save(TestData.validServer(), replacing: nil)
        let renamed = try await service(id: "other").save(
            TestData.validServer(TestData.form(name: "Away")),
            replacing: original
        )
        #expect(renamed.id == original.id)
        #expect(renamed.createdAt == original.createdAt)
        #expect(try await ServerStore(database: database).all().map(\.name) == ["Away"])
    }

    @Test
    func `deleting removes the profile and its keychain secrets`() async throws {
        let profile = try await service().save(TestData.validServer(), replacing: nil)
        try await service().delete(profile)
        #expect(try await ServerStore(database: database).all().isEmpty)
        #expect(keychain.keys.isEmpty)
    }

    @Test
    func `ing pings the public address`() async throws {
        let info = try await service().test(TestData.validServer())
        #expect(info == PingStub.info)
        #expect(pings.asked.map(\.absoluteString) == [TestData.address])
    }

    @Test
    func `ing falls back to the local address when the public one fails`() async throws {
        pings.set(TestData.address, .failure(.transport(.cannotConnectToHost)))
        var form = TestData.form()
        form.usesLocalAddress = true
        form.localAddress = "http://192.168.1.10"
        _ = try await service().test(TestData.validServer(form))
        #expect(pings.asked.count == 2)
    }

    @Test
    func `a failed test reports the public address's error`() async throws {
        pings.set(TestData.address, .failure(.server(code: .wrongCredentials, message: nil)))
        await #expect(throws: AccountError.connection(.server(code: .wrongCredentials, message: nil))) {
            try await service().test(TestData.validServer())
        }
    }

    @Test
    func `credentials load the secrets for the saved addresses`() async throws {
        let profile = try await service().save(TestData.validServer(), replacing: nil)
        let credentials = try await service().credentials(for: profile)
        let client = credentials.client(at: profile.address)
        #expect(client.auth.username == "alice")
        #expect(client.server == profile.address)
    }

    @Test
    func `credentials for an edited address ask for the password again`() async throws {
        let profile = try await service().save(TestData.validServer(), replacing: nil)
        let moved = try ServerProfile(
            id: profile.id, name: profile.name, username: profile.username,
            address: ServerAddress("https://elsewhere.example.com"), localAddress: nil,
            usesPlaintextPassword: false, createdAt: profile.createdAt
        )
        await #expect(throws: AccountError.passwordNeeded) { try await service().credentials(for: moved) }
    }

    @Test
    func `a stored certificate is imported for the session`() async throws {
        var form = TestData.form()
        form.usesClientCertificate = true
        form.clientCertificate = try CertificateFile(
            data: ClientCertificateImportTests.fixture(), passphrase: "tempus-test", subject: "Tempus Test Client"
        )
        let profile = try await service().save(TestData.validServer(form), replacing: nil)
        let credentials = try await service().credentials(for: profile)
        #expect(credentials.certificateSubject == "Tempus Test Client")
        #expect(await service().formForEditing(profile).clientCertificate?.subject == "Tempus Test Client")
    }

    @Test
    func `account errors have messages`() {
        #expect(AccountError.passwordNeeded.userMessage.contains("password"))
        #expect(AccountError.storage.userMessage.contains("Keychain"))
        #expect(AccountError.keychainUnavailable.userMessage.contains("Keychain"))
        #expect(AccountError.connection(.httpStatus(500)).userMessage == SubsonicError.httpStatus(500).userMessage)
    }
}

/// A Keychain that refuses every read, as macOS does when access is denied.
private final class DeniedSecretStore: SecretStore {
    func data(for _: String) throws(SecretStoreError) -> Data? {
        throw .unexpectedStatus(errSecAuthFailed)
    }

    func set(_: Data, for _: String) throws(SecretStoreError) {}
    func removeData(for _: String) throws(SecretStoreError) {}
}

struct AccountServiceKeychainTests {
    @Test
    func `a Keychain that refuses access is reported as such, not as a missing password`() async throws {
        let database = try AppDatabase.inMemory()
        let profile = try await TestData.saveServer(in: database)
        let service = AccountService(database: database, secrets: ServerSecretStore(store: DeniedSecretStore()))
        await #expect(throws: AccountError.keychainUnavailable) { try await service.credentials(for: profile) }
    }
}

/// Records whether the Keychain was read on the main thread, where a permission prompt would
/// freeze the app.
private final class ThreadCheckingSecretStore: SecretStore {
    let readOnMain = Mutex<Bool?>(nil)
    private let inner = MemorySecretStore()

    func data(for key: String) throws(SecretStoreError) -> Data? {
        let onMain = Thread.isMainThread
        readOnMain.withLock { $0 = onMain }
        return try inner.data(for: key)
    }

    func set(_ data: Data, for key: String) throws(SecretStoreError) {
        try inner.set(data, for: key)
    }

    func removeData(for key: String) throws(SecretStoreError) {
        try inner.removeData(for: key)
    }
}

@MainActor
struct AccountServiceThreadingTests {
    @Test
    func `credentials read the Keychain off the main thread, even when asked from it`() async throws {
        let database = try AppDatabase.inMemory()
        let store = ThreadCheckingSecretStore()
        let service = AccountService(database: database, secrets: ServerSecretStore(store: store))
        let profile = try await service.save(TestData.validServer(), replacing: nil)

        _ = try await service.credentials(for: profile)

        #expect(store.readOnMain.withLock { $0 } == false)
    }
}

/// A Keychain that can be read and written but refuses deletions.
private final class UndeletableSecretStore: SecretStore {
    private let inner = MemorySecretStore()

    func data(for key: String) throws(SecretStoreError) -> Data? {
        try inner.data(for: key)
    }

    func set(_ data: Data, for key: String) throws(SecretStoreError) {
        try inner.set(data, for: key)
    }

    func removeData(for _: String) throws(SecretStoreError) {
        throw .unexpectedStatus(errSecInteractionNotAllowed)
    }
}

struct AccountServiceDeletionTests {
    @Test
    func `a server whose secrets can't be removed is kept, so deleting can be retried`() async throws {
        let database = try AppDatabase.inMemory()
        let service = AccountService(database: database, secrets: ServerSecretStore(store: UndeletableSecretStore()))
        let profile = try await service.save(TestData.validServer(), replacing: nil)

        await #expect(throws: AccountError.storage) { try await service.delete(profile) }

        #expect(try await ServerStore(database: database).all().map(\.id) == [profile.id])
    }

    @Test
    func `descriptions never show the password, headers or certificate passphrase`() throws {
        var form = TestData.form(password: "hunter2")
        form.usesCustomHeaders = true
        form.customHeaders = "X-Token: hunter3"
        form.usesClientCertificate = true
        form.clientCertificate = try CertificateFile(data: Data([1]), passphrase: "hunter4", subject: "Me")
        let server = try form.validated().get()

        for text in [String(describing: form), String(reflecting: server), String(describing: form.clientCertificate)] {
            #expect(!text.contains("hunter"))
        }
    }
}
