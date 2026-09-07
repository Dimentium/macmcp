import Foundation
import XCTest
@testable import MacMCPBridge

private final class InMemoryManagedDraftCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [String: Data] = [:]

    func readSecret(account: String) throws -> Data {
        guard let value = values[account] else { throw CredentialStoreError.notFound }
        return value
    }

    func storeSecret(_ secret: Data, account: String) throws {
        values[account] = secret
    }

    func deleteSecret(account: String) throws {
        values.removeValue(forKey: account)
    }
}

final class ManagedDraftKeyStoreTests: XCTestCase {
    func testCreatesAndReusesStableKey() throws {
        let credentials = InMemoryManagedDraftCredentialStore()
        let store = ManagedDraftKeyStore(credentials: credentials)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        XCTAssertEqual(first.count, ManagedDraftKeyStore.keyLength)
        XCTAssertEqual(second, first)
    }
}
