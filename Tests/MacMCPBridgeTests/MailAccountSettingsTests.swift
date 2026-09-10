import Foundation
import XCTest
@testable import MacMCPBridge

final class MailAccountSettingsTests: XCTestCase {
    func testAddUpdateAndRemoveMultipleAccountsWithoutIDCollision() throws {
        let launchStore = AppLaunchConfigurationStore(fileURL: try temporaryFileURL())
        let credentials = TestCredentialStore()
        let store = MailAccountConfigurationStore(
            launchConfigurationStore: launchStore,
            credentialStore: credentials
        )

        let first = try store.save(
            accountID: nil,
            provider: .gmail,
            username: "one@gmail.com",
            imapHost: "",
            imapPort: 993,
            imapSecurity: .tls,
            password: Data("one-password".utf8)
        )
        let second = try store.save(
            accountID: nil,
            provider: .gmail,
            username: "two@gmail.com",
            imapHost: "",
            imapPort: 993,
            imapSecurity: .tls,
            password: Data("two-password".utf8)
        )
        XCTAssertEqual(first.id, "gmail")
        XCTAssertEqual(second.id, "gmail2")

        let other = try store.save(
            accountID: nil,
            provider: .otherIMAP,
            username: "alex",
            imapHost: "imap.example.com",
            imapPort: 993,
            imapSecurity: .tls,
            password: Data("other-password".utf8)
        )
        XCTAssertEqual(other.username, "alex")
        XCTAssertEqual(
            try launchStore.readConfiguration()?.args,
            [
                "--gmail-address", "one@gmail.com",
                "--gmail-address", "two@gmail.com",
                "--mail-account", "imap=alex,imap.example.com,993,tls"
            ]
        )

        _ = try store.save(
            accountID: second.id,
            provider: .gmail,
            username: "two@gmail.com",
            imapHost: "",
            imapPort: 993,
            imapSecurity: .tls,
            password: nil
        )
        XCTAssertEqual(credentials.secrets["two@gmail.com"], Data("two-password".utf8))

        try store.remove(accountID: first.id)
        XCTAssertNil(credentials.secrets["one@gmail.com"])
        XCTAssertEqual(
            try launchStore.readConfiguration()?.args,
            [
                "--gmail-address", "two@gmail.com",
                "--mail-account", "imap=alex,imap.example.com,993,tls"
            ]
        )
    }

    func testMailAddressValidatorChecksRFCAndProviderDomain() {
        XCTAssertNil(MailAccountAddressValidator.message(
            for: "person@icloud.com",
            provider: .iCloud
        ))
        XCTAssertEqual(
            MailAccountAddressValidator.message(for: "person@example.com", provider: .gmail),
            "Gmail accounts must use a gmail.com address."
        )
        XCTAssertEqual(
            MailAccountAddressValidator.message(for: "person@@gmail.com", provider: .gmail),
            "Enter a valid email address."
        )
        XCTAssertNil(MailAccountAddressValidator.message(for: "alex", provider: .otherIMAP))
    }

    func testMailAccountAccessPersistsDisabledAccounts() async throws {
        let fileURL = try temporaryFileURL()
        let store = MailAccountAccessStore(fileURL: fileURL)
        let configured: Set<String> = ["gmail", "icloud"]

        let initiallyEnabled = await store.enabledAccountIDs(for: configured)
        XCTAssertEqual(initiallyEnabled, configured)
        try await store.setEnabled(false, for: "gmail")
        let afterDisable = await store.enabledAccountIDs(for: configured)
        XCTAssertEqual(afterDisable, ["icloud"])

        let reloaded = MailAccountAccessStore(fileURL: fileURL)
        let reloadedDisabled = await reloaded.enabledAccountIDs(for: configured)
        XCTAssertEqual(reloadedDisabled, ["icloud"])
        try await reloaded.setEnabled(true, for: "gmail")
        let reloadedEnabled = await reloaded.enabledAccountIDs(for: configured)
        XCTAssertEqual(reloadedEnabled, configured)
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }
}

private final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private(set) var secrets: [String: Data] = [:]

    func readSecret(account: String) throws -> Data {
        guard let secret = secrets[account] else { throw CredentialStoreError.notFound }
        return secret
    }

    func storeSecret(_ secret: Data, account: String) throws {
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        secrets.removeValue(forKey: account)
    }
}
