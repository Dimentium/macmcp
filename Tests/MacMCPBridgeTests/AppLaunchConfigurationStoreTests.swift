import Foundation
import XCTest
@testable import MacMCPBridge

final class AppLaunchConfigurationStoreTests: XCTestCase {
    func testReadsStoredLaunchArguments() throws {
        let fileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "launchAtLogin": true,
          "args": [
            "--mail-sidecar",
            "/Users/example/.local/opt/macmcp/libexec/mail-mcp",
            "--gmail-address",
            "reader@gmail.com"
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let args = try AppLaunchConfigurationStore(fileURL: fileURL).readArguments()
        let configuration = try AppLaunchConfigurationStore(fileURL: fileURL).readConfiguration()

        XCTAssertEqual(args, [
            "--mail-sidecar",
            "/Users/example/.local/opt/macmcp/libexec/mail-mcp",
            "--gmail-address",
            "reader@gmail.com"
        ])
        XCTAssertEqual(configuration?.launchAtLogin, true)
    }

    func testMissingLaunchConfigReturnsNil() throws {
        let fileURL = try temporaryFileURL()

        XCTAssertNil(try AppLaunchConfigurationStore(fileURL: fileURL).readArguments())
    }

    func testFallsBackToLegacyLaunchConfig() throws {
        let fileURL = try temporaryFileURL()
        let legacyFileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "args": ["--gmail-address", "reader@gmail.com"]
        }
        """.write(to: legacyFileURL, atomically: true, encoding: .utf8)

        let configuration = try AppLaunchConfigurationStore(
            fileURL: fileURL,
            legacyFileURL: legacyFileURL
        ).readConfiguration()

        XCTAssertEqual(configuration?.args, ["--gmail-address", "reader@gmail.com"])
    }

    func testRejectsPasswordCommandInLaunchConfig() throws {
        let fileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "args": ["--store-mail-password", "reader@gmail.com"]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try AppLaunchConfigurationStore(fileURL: fileURL).readArguments()
        ) { error in
            XCTAssertEqual(
                error as? AppLaunchConfigurationError,
                .passwordCommandNotAllowed
            )
        }
    }

    func testRejectsStdioProxyInLaunchConfig() throws {
        let fileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "args": ["--stdio-proxy", "/tmp/mcp.sock"]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try AppLaunchConfigurationStore(fileURL: fileURL).readArguments()
        ) { error in
            XCTAssertEqual(
                error as? AppLaunchConfigurationError,
                .passwordCommandNotAllowed
            )
        }
    }

    func testRejectsControlCharactersInLaunchConfig() throws {
        let fileURL = try temporaryFileURL()
        let data = Data("""
        {
          "schemaVersion": 1,
          "args": ["--gmail-address", "reader\\u0001@gmail.com"]
        }
        """.utf8)
        try data.write(to: fileURL)

        XCTAssertThrowsError(
            try AppLaunchConfigurationStore(fileURL: fileURL).readArguments()
        ) { error in
            XCTAssertEqual(error as? AppLaunchConfigurationError, .invalidArgument)
        }
    }

    func testReadsValidatedChatGPTTunnelConfiguration() throws {
        let fileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "args": [],
          "chatGPTTunnel": {
            "tunnelID": "tunnel_0123456789abcdef0123456789abcdef",
            "clientPath": "/opt/homebrew/bin/tunnel-client",
            "profile": "macmcp-local"
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let configuration = try AppLaunchConfigurationStore(fileURL: fileURL).readConfiguration()

        XCTAssertEqual(
            configuration?.chatGPTTunnel,
            ChatGPTTunnelConfiguration(
                tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                clientPath: "/opt/homebrew/bin/tunnel-client",
                profile: "macmcp-local"
            )
        )
    }

    func testRejectsUnsafeChatGPTTunnelConfiguration() throws {
        let fileURL = try temporaryFileURL()
        try """
        {
          "schemaVersion": 1,
          "args": [],
          "chatGPTTunnel": {
            "tunnelID": "not-a-tunnel",
            "clientPath": "/tmp/other-command",
            "profile": "bad profile"
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try AppLaunchConfigurationStore(fileURL: fileURL).readConfiguration()
        ) { error in
            XCTAssertEqual(
                error as? AppLaunchConfigurationError,
                .invalidChatGPTTunnelConfiguration
            )
        }
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("launch.json")
    }
}
