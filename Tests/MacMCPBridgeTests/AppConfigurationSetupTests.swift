import Foundation
import XCTest
@testable import MacMCPBridge

final class AppConfigurationSetupTests: XCTestCase {
    func testConfiguresAccountsTunnelAndLoginItem() throws {
        let launchStore = AppLaunchConfigurationStore(fileURL: try temporaryFileURL())
        let mailStore = InMemoryCredentialStore()
        let tunnelStore = InMemoryCredentialStore()
        let loginItem = FakeLoginItemController()
        var passwords = [Data("mail-secret".utf8)]

        try AppConfigurationSetup.configure(
            arguments: [
                "--gmail-address", "reader@gmail.com",
                "--chatgpt-tunnel-id", "tunnel_0123456789abcdef0123456789abcdef",
                "--chatgpt-tunnel-client", "/opt/homebrew/bin/tunnel-client"
            ],
            launchConfigurationStore: launchStore,
            mailCredentialStore: mailStore,
            tunnelCredentialStore: tunnelStore,
            loginItemController: loginItem,
            readMailPassword: { passwords.removeFirst() },
            readTunnelKey: { Data("tunnel-secret".utf8) }
        )

        XCTAssertEqual(
            try launchStore.readConfiguration(),
            AppLaunchConfigurationStore.Configuration(
                args: ["--gmail-address", "reader@gmail.com"],
                launchAtLogin: true,
                chatGPTTunnel: ChatGPTTunnelConfiguration(
                    tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                    clientPath: "/opt/homebrew/bin/tunnel-client",
                    profile: "macmcp-local"
                )
            )
        )
        XCTAssertEqual(mailStore.secrets["reader@gmail.com"], Data("mail-secret".utf8))
        XCTAssertEqual(
            tunnelStore.secrets[KeychainCredentialStore.chatGPTTunnelAccount],
            Data("tunnel-secret".utf8)
        )
        XCTAssertEqual(loginItem.registerCalls, 1)
    }

    func testAllowsSetupWithoutMailAccountOrTunnel() throws {
        XCTAssertEqual(
            try AppConfigurationSetup.parse(arguments: []),
            AppConfigurationSetup.Request(
                launchArguments: [],
                mailAccounts: [],
                launchAtLogin: true,
                chatGPTTunnel: nil
            )
        )
    }

    func testConfiguresTunnelWithoutMailAccount() throws {
        let launchStore = AppLaunchConfigurationStore(fileURL: try temporaryFileURL())
        let tunnelStore = InMemoryCredentialStore()

        try AppConfigurationSetup.configure(
            arguments: [
                "--chatgpt-tunnel-id", "tunnel_0123456789abcdef0123456789abcdef",
                "--chatgpt-tunnel-client", "/Applications/MacMCP.app/Contents/Resources/tunnel-client/tunnel-client"
            ],
            launchConfigurationStore: launchStore,
            tunnelCredentialStore: tunnelStore,
            readTunnelKey: { Data("tunnel-secret".utf8) }
        )

        XCTAssertEqual(try launchStore.readConfiguration()?.args, [])
        XCTAssertEqual(try launchStore.readConfiguration()?.chatGPTTunnel?.tunnelID, "tunnel_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(
            tunnelStore.secrets[KeychainCredentialStore.chatGPTTunnelAccount],
            Data("tunnel-secret".utf8)
        )
    }

    func testRejectsTunnelIDWithoutClient() throws {
        XCTAssertThrowsError(try AppConfigurationSetup.parse(arguments: [
            "--gmail-address", "reader@gmail.com",
            "--chatgpt-tunnel-id", "tunnel_0123456789abcdef0123456789abcdef"
        ])) { error in
            XCTAssertEqual(error as? AppConfigurationSetupError, .tunnelIDRequiresClient)
        }
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("launch.json")
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
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

private final class FakeLoginItemController: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered
    private(set) var registerCalls = 0

    func register() throws {
        registerCalls += 1
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }
}
