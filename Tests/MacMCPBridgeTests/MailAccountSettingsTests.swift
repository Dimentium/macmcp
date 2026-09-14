import Foundation
import XCTest
@testable import MacMCPBridge

final class MailAccountSettingsTests: XCTestCase {
    func testPermissionOnlyUpdateDoesNotReadCredentialsOrRewriteLaunchConfiguration() async throws {
        let launchURL = try temporaryFileURL()
        let launchStore = AppLaunchConfigurationStore(fileURL: launchURL)
        try launchStore.write(
            arguments: ["--gmail-address", "reader@gmail.com"],
            launchAtLogin: true
        )
        let originalLaunchData = try Data(contentsOf: launchURL)
        let accessStore = MailActionAccessStore(
            fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-actions.json")
        )
        let accountAccessStore = MailAccountAccessStore(
            fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-accounts.json")
        )
        let updater = MailAccountSettingsUpdater(
            configurationStore: MailAccountConfigurationStore(
                launchConfigurationStore: launchStore,
                credentialStore: FailingCredentialStore()
            ),
            actionAccessStore: accessStore,
            accountAccessStore: accountAccessStore
        )
        let existing = try MailAccountConfiguration.gmail(address: "reader@gmail.com")

        let result = try await updater.save(
            accountID: existing.id,
            existingAccount: existing,
            form: SettingsMailAccountForm(
                provider: .gmail,
                username: existing.username,
                password: "",
                imapHost: existing.imapHost,
                imapPort: existing.imapPort,
                imapSecurity: existing.imapSecurity,
                draftsCreationAllowed: true
            )
        )

        XCTAssertEqual(result.accountID, "gmail")
        XCTAssertFalse(result.requiresRestart)
        XCTAssertEqual(try Data(contentsOf: launchURL), originalLaunchData)
        let gmailIsWritable = await accessStore.isWritable(accountID: "gmail")
        XCTAssertTrue(gmailIsWritable)
    }

    func testPermissionOnlyUpdatePreservesOtherAccountsAccess() async throws {
        let launchURL = try temporaryFileURL()
        let launchStore = AppLaunchConfigurationStore(fileURL: launchURL)
        try launchStore.write(
            arguments: [
                "--gmail-address", "reader@gmail.com",
                "--icloud-address", "reader@icloud.com"
            ],
            launchAtLogin: true
        )
        let accessStore = MailActionAccessStore(
            fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-actions.json")
        )
        try await accessStore.setReadOnly(false, for: "gmail")
        try await accessStore.setReadOnly(false, for: "icloud")
        let updater = MailAccountSettingsUpdater(
            configurationStore: MailAccountConfigurationStore(
                launchConfigurationStore: launchStore,
                credentialStore: FailingCredentialStore()
            ),
            actionAccessStore: accessStore,
            accountAccessStore: MailAccountAccessStore(
                fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-accounts.json")
            )
        )
        let existing = try MailAccountConfiguration.gmail(address: "reader@gmail.com")

        _ = try await updater.save(
            accountID: existing.id,
            existingAccount: existing,
            form: SettingsMailAccountForm(
                provider: .gmail,
                username: existing.username,
                password: "",
                imapHost: existing.imapHost,
                imapPort: existing.imapPort,
                imapSecurity: existing.imapSecurity,
                draftsCreationAllowed: false
            )
        )

        let gmailIsWritable = await accessStore.isWritable(accountID: "gmail")
        let iCloudIsWritable = await accessStore.isWritable(accountID: "icloud")
        XCTAssertFalse(gmailIsWritable)
        XCTAssertTrue(iCloudIsWritable)
    }

    func testPermissionOnlyUpdateRefreshesWriteCapabilityWithoutRestart() async throws {
        let launchURL = try temporaryFileURL()
        let launchStore = AppLaunchConfigurationStore(fileURL: launchURL)
        try launchStore.write(
            arguments: ["--gmail-address", "reader@gmail.com"],
            launchAtLogin: true
        )
        let accessStore = MailActionAccessStore(
            fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-actions.json")
        )
        let updater = MailAccountSettingsUpdater(
            configurationStore: MailAccountConfigurationStore(
                launchConfigurationStore: launchStore,
                credentialStore: FailingCredentialStore()
            ),
            actionAccessStore: accessStore,
            accountAccessStore: MailAccountAccessStore(
                fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-accounts.json")
            )
        )
        let existing = try MailAccountConfiguration.gmail(address: "reader@gmail.com")
        let statusSource = BridgeStatusSource(status: .connected(mail: true, eventKit: false))

        let result = try await updater.save(
            accountID: existing.id,
            existingAccount: existing,
            form: SettingsMailAccountForm(
                provider: .gmail,
                username: existing.username,
                password: "",
                imapHost: existing.imapHost,
                imapPort: existing.imapPort,
                imapSecurity: existing.imapSecurity,
                draftsCreationAllowed: true
            )
        )
        let writableAccountIDs = await accessStore.writableAccountIDs()
        await statusSource.updateWriteCapabilitiesEnabled(!writableAccountIDs.isEmpty)
        let status = await statusSource.snapshot()

        XCTAssertFalse(result.requiresRestart)
        XCTAssertTrue(status.writeCapabilitiesEnabled)
        XCTAssertEqual(try launchStore.readConfiguration()?.args, ["--gmail-address", "reader@gmail.com"])
    }

    func testSignificantUpdatePersistsConfigurationAndRequiresRestart() async throws {
        let launchURL = try temporaryFileURL()
        let launchStore = AppLaunchConfigurationStore(fileURL: launchURL)
        try launchStore.write(
            arguments: ["--mail-account", "imap=alex,imap.old.example,993,tls"],
            launchAtLogin: true
        )
        let credentials = TestCredentialStore()
        try credentials.storeSecret(Data("current-password".utf8), account: "alex")
        let updater = MailAccountSettingsUpdater(
            configurationStore: MailAccountConfigurationStore(
                launchConfigurationStore: launchStore,
                credentialStore: credentials
            ),
            actionAccessStore: MailActionAccessStore(
                fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-actions.json")
            ),
            accountAccessStore: MailAccountAccessStore(
                fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("mail-accounts.json")
            )
        )
        let existing = try MailAccountConfiguration(
            id: "imap",
            username: "alex",
            imapHost: "imap.old.example",
            imapPort: 993,
            imapSecurity: .tls
        )

        let result = try await updater.save(
            accountID: existing.id,
            existingAccount: existing,
            form: SettingsMailAccountForm(
                provider: .otherIMAP,
                username: "alex",
                password: "",
                imapHost: "imap.new.example",
                imapPort: 993,
                imapSecurity: .tls,
                draftsCreationAllowed: false
            )
        )

        XCTAssertTrue(result.requiresRestart)
        XCTAssertEqual(
            try launchStore.readConfiguration()?.args,
            ["--mail-account", "imap=alex,imap.new.example,993,tls"]
        )
    }

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

    func testTunnelConfigurationStoresKeySeparatelyFromLaunchJSON() throws {
        let launchURL = try temporaryFileURL()
        let launchStore = AppLaunchConfigurationStore(fileURL: launchURL)
        let credentials = TestCredentialStore()
        let tunnelID = "tunnel_0123456789abcdef0123456789abcdef"

        try AppConfigurationSetup.configureTunnel(
            tunnelID: tunnelID,
            clientPath: "/opt/homebrew/bin/tunnel-client",
            runtimeKey: Data("runtime-secret".utf8),
            launchConfigurationStore: launchStore,
            tunnelCredentialStore: credentials
        )

        let launchText = try String(contentsOf: launchURL, encoding: .utf8)
        XCTAssertTrue(launchText.contains(tunnelID))
        XCTAssertFalse(launchText.contains("runtime-secret"))
        XCTAssertEqual(
            credentials.secrets[KeychainCredentialStore.chatGPTTunnelAccount],
            Data("runtime-secret".utf8)
        )
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

private struct FailingCredentialStore: CredentialStore {
    func readSecret(account: String) throws -> Data {
        throw CredentialStoreError.notFound
    }

    func storeSecret(_ secret: Data, account: String) throws {
        throw CredentialStoreError.notFound
    }

    func deleteSecret(account: String) throws {}
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
