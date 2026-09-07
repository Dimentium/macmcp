import Foundation
import XCTest
@testable import MacMCPBridge

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [String: Data]

    init(values: [String: Data] = [:]) {
        self.values = values
    }

    func readSecret(account: String) throws -> Data {
        guard let value = values[account] else {
            throw CredentialStoreError.notFound
        }
        return value
    }

    func storeSecret(_ secret: Data, account: String) throws {
        values[account] = secret
    }

    func deleteSecret(account: String) throws {
        values.removeValue(forKey: account)
    }
}

final class CredentialStoreMigrationTests: XCTestCase {
    func testReadsLegacySecretAndCopiesItToCanonicalStore() throws {
        let secret = Data("mail-app-password".utf8)
        let primary = InMemoryCredentialStore()
        let legacy = InMemoryCredentialStore(values: ["reader@example.com": secret])
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        XCTAssertEqual(try store.readSecret(account: "reader@example.com"), secret)
        XCTAssertEqual(try primary.readSecret(account: "reader@example.com"), secret)
    }

    func testDeletesBothCanonicalAndLegacySecrets() throws {
        let secret = Data("runtime-key".utf8)
        let primary = InMemoryCredentialStore(values: ["runtime": secret])
        let legacy = InMemoryCredentialStore(values: ["runtime": secret])
        let store = MigratingCredentialStore(primary: primary, legacy: legacy)

        try store.deleteSecret(account: "runtime")

        XCTAssertThrowsError(try primary.readSecret(account: "runtime"))
        XCTAssertThrowsError(try legacy.readSecret(account: "runtime"))
    }
}
