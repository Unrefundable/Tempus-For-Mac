import Foundation
@testable import SecureStorage
import Synchronization
import Testing

/// Keeps secrets in memory, for testing code that uses a `SecretStore`.
private final class MemoryStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    func data(for key: String) throws(SecretStoreError) -> Data? {
        items.withLock { $0[key] }
    }

    func set(_ data: Data, for key: String) throws(SecretStoreError) {
        items.withLock { $0[key] = data }
    }

    func removeData(for key: String) throws(SecretStoreError) {
        _ = items.withLock { $0.removeValue(forKey: key) }
    }
}

@Suite("Server secrets")
struct ServerSecretStoreTests {
    @Test("Secrets round-trip per server and can be removed")
    func roundTrip() throws {
        let store = ServerSecretStore(store: MemoryStore())
        let secrets = ServerSecrets(password: "p@ss+word é", customHeaders: "CF-Access-Client-Id: abc")

        try store.save(secrets, forServer: "srv-1")

        #expect(try store.secrets(forServer: "srv-1") == secrets)
        #expect(try store.secrets(forServer: "srv-2") == nil)

        try store.remove(forServer: "srv-1")
        #expect(try store.secrets(forServer: "srv-1") == nil)
    }

    @Test("Descriptions never reveal the password or header values")
    func redactedDescription() {
        let secrets = ServerSecrets(password: "hunter2", customHeaders: "X-Token: hunter3")

        #expect(!String(describing: secrets).contains("hunter"))
        #expect(!String(reflecting: secrets).contains("hunter"))
    }

    @Test("Unreadable stored data is reported, not silently dropped")
    func corruptData() throws {
        let memory = MemoryStore()
        try memory.set(Data("not json".utf8), for: "server.srv-1")

        #expect(throws: SecretStoreError.decodingFailed) {
            try ServerSecretStore(store: memory).secrets(forServer: "srv-1")
        }
    }
}

/// Talks to the real login keychain, so it only runs when TEMPUS_KEYCHAIN_TESTS=1.
@Suite(
    "Keychain store (login keychain)",
    .enabled(if: ProcessInfo.processInfo.environment["TEMPUS_KEYCHAIN_TESTS"] == "1")
)
struct KeychainStoreTests {
    @Test("Writes, overwrites, reads and deletes a generic password")
    func lifecycle() throws {
        let store = KeychainStore(service: "io.github.unrefundable.TempusMac.tests.\(UUID().uuidString)")
        defer { try? store.removeData(for: "key") }

        #expect(try store.data(for: "key") == nil)
        try store.set(Data("first".utf8), for: "key")
        try store.set(Data("second".utf8), for: "key")
        #expect(try store.data(for: "key") == Data("second".utf8))

        try store.removeData(for: "key")
        #expect(try store.data(for: "key") == nil)
        try store.removeData(for: "key")
    }
}
