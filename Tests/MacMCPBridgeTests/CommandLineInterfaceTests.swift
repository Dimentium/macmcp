import XCTest
@testable import MacMCPBridge

final class CommandLineInterfaceTests: XCTestCase {
    func testSecretInputLimitSupportsLongRuntimeKeys() {
        XCTAssertGreaterThanOrEqual(CommandLineInterface.maximumSecretLength, 164)
    }

    func testParsesSidecarPathsWithoutSecrets() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--mail-sidecar", "/opt/mail-mcp",
            "--icloud-address", "reader@icloud.com",
            "--eventkit-sidecar", "/opt/CheICalMCP"
        ])

        XCTAssertEqual(configuration.mailSidecarURL?.path, "/opt/mail-mcp")
        XCTAssertEqual(configuration.eventKitSidecarURL?.path, "/opt/CheICalMCP")
        XCTAssertEqual(configuration.iCloudAddress, "reader@icloud.com")
        XCTAssertEqual(configuration.mailAccounts.map(\.id), ["icloud"])
        XCTAssertFalse(configuration.menuBar)
        XCTAssertTrue(configuration.requiresAppOwnedRuntime)
    }

    func testParsesGmailPresetWithoutSecrets() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--mail-sidecar", "/opt/mail-mcp",
            "--gmail-address", "reader@gmail.com"
        ])

        XCTAssertEqual(configuration.mailAccounts.count, 1)
        XCTAssertEqual(configuration.mailAccounts[0].id, "gmail")
        XCTAssertEqual(configuration.mailAccounts[0].username, "reader@gmail.com")
        XCTAssertEqual(configuration.mailAccounts[0].imapHost, "imap.gmail.com")
        XCTAssertEqual(configuration.mailAccounts[0].imapPort, 993)
        XCTAssertEqual(configuration.mailAccounts[0].imapSecurity, .tls)
    }

    func testHelpDocumentsStdioProxy() {
        XCTAssertTrue(CommandLineInterface.help.contains("--stdio-proxy SOCKET_PATH"))
        XCTAssertTrue(CommandLineInterface.help.contains("--diagnose-json"))
        XCTAssertTrue(CommandLineInterface.help.contains("--client-approvals-json"))
        XCTAssertTrue(CommandLineInterface.help.contains("--approve-pending-client"))
        XCTAssertTrue(CommandLineInterface.help.contains("--revoke-client FINGERPRINT"))
        XCTAssertTrue(CommandLineInterface.help.contains("--store-chatgpt-tunnel-key"))
        XCTAssertTrue(CommandLineInterface.help.contains("--delete-chatgpt-tunnel-key"))
        XCTAssertTrue(CommandLineInterface.help.contains("--verify-configured-mail-keychain"))
    }

    func testParsesMultipleMailAccounts() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--mail-sidecar", "/opt/mail-mcp",
            "--icloud-address", "reader@icloud.com",
            "--gmail-address", "reader@gmail.com",
            "--mail-account", "work=reader@example.com,imap.example.com,993,tls"
        ])

        XCTAssertEqual(configuration.mailAccounts.map(\.id), ["icloud", "gmail", "work"])
        XCTAssertEqual(configuration.mailAccounts.map(\.username), [
            "reader@icloud.com",
            "reader@gmail.com",
            "reader@example.com"
        ])
        XCTAssertEqual(configuration.mailAccounts[2].imapHost, "imap.example.com")
    }

    func testRepeatedGmailPresetGetsStableUniqueID() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--gmail-address", "one@gmail.com",
            "--gmail-address", "two@gmail.com"
        ])

        XCTAssertEqual(configuration.mailAccounts.map(\.id), ["gmail", "gmail2"])
    }

    func testParsesMenuBarFlag() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: ["--menu-bar"])
        XCTAssertTrue(configuration.menuBar)
        XCTAssertFalse(configuration.requiresAppOwnedRuntime)
    }

    func testAcceptsLegacyLocalMailActionsFlagAsNoOp() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--enable-local-mail-actions"
        ])

        XCTAssertTrue(configuration.mailAccounts.isEmpty)
    }

    func testRejectsPlainIMAPWithoutExplicitUnsafeOverride() {
        XCTAssertThrowsError(
            try CommandLineInterface.launchConfiguration(arguments: [
                "--mail-account", "legacy=reader@example.com,imap.example.com,143,plain"
            ])
        ) { error in
            XCTAssertEqual(
                error as? CommandLineInterfaceError,
                .invalidMailAccount("legacy=reader@example.com,imap.example.com,143,plain")
            )
        }
    }

    func testParsesPlainIMAPOnlyWithExplicitUnsafeOverride() throws {
        let configuration = try CommandLineInterface.launchConfiguration(arguments: [
            "--mail-account", "legacy=reader@example.com,imap.example.com,143,plain",
            "--allow-unsafe-plain-imap"
        ])

        XCTAssertEqual(configuration.mailAccounts.first?.imapSecurity, .plain)
    }

    func testAppBundleDefaultsToMenuBarAndEmbeddedEventKitSidecar() throws {
        let configuration = try CommandLineInterface.launchConfiguration(
            arguments: [],
            bundleURL: URL(fileURLWithPath: "/Applications/MacMCP.app"),
            resourceURL: { name in
                URL(fileURLWithPath: "/Applications/MacMCP.app/Contents/Resources/\(name)")
            }
        )

        XCTAssertTrue(configuration.menuBar)
        XCTAssertEqual(
            configuration.eventKitSidecarURL?.path,
            "/Applications/MacMCP.app/Contents/Resources/CheICalMCP"
        )
    }

    func testRejectsUnknownOption() {
        XCTAssertThrowsError(
            try CommandLineInterface.launchConfiguration(arguments: ["--password", "secret"])
        ) { error in
            XCTAssertEqual(error as? CommandLineInterfaceError, .unknownOption("--password"))
        }
    }

    func testRejectsInvalidMailAccountSpec() {
        XCTAssertThrowsError(
            try CommandLineInterface.launchConfiguration(arguments: ["--mail-account", "work"])
        ) { error in
            XCTAssertEqual(error as? CommandLineInterfaceError, .invalidMailAccount("work"))
        }
    }
}
