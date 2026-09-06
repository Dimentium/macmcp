import Foundation
import XCTest
@testable import MacAgentBridge

final class DiagnosticsTests: XCTestCase {
    func testReportSummarizesRuntimeWithoutSerializingPrivateConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tunnelClient = directory.appendingPathComponent("tunnel-client")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: tunnelClient)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tunnelClient.path)

        let launchConfiguration = directory.appendingPathComponent("launch.json")
        let privateAddress = "reader.private@example.com"
        let privateTunnelID = "tunnel_0123456789abcdef0123456789abcdef"
        try """
        {
          "schemaVersion": 1,
          "launchAtLogin": true,
          "args": [
            "--mail-sidecar", "/private/runtime/mail-mcp",
            "--gmail-address", "\(privateAddress)"
          ],
          "chatGPTTunnel": {
            "tunnelID": "\(privateTunnelID)",
            "clientPath": "\(tunnelClient.path)",
            "profile": "macmcp-local"
          }
        }
        """.write(to: launchConfiguration, atomically: true, encoding: .utf8)

        let status = BridgeStatus(
            version: AppVersion.version,
            mode: .reader,
            mail: .ready,
            calendar: .ready,
            reminders: .ready,
            mailRestartCount: 2,
            eventKitRestartCount: 1,
            writeCapabilitiesEnabled: false
        )
        let collector = MacMCPDiagnosticCollector(
            launchConfigurationStore: AppLaunchConfigurationStore(fileURL: launchConfiguration),
            clientApprovalStore: ClientApprovalStore(fileURL: directory.appendingPathComponent("clients.json")),
            bridgeStatusRequest: { try status.encodedJSON() },
            loginItemStatus: { .enabled },
            tunnelHealthProbe: { _ in true }
        )

        let report = await collector.collect()
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.configuration.availability, .available)
        XCTAssertEqual(report.configuration.mailAccountCount, 1)
        XCTAssertTrue(report.configuration.launchAtLogin)
        XCTAssertEqual(report.bridge.availability, .available)
        XCTAssertEqual(report.bridge.status?.mailRestartCount, 2)
        XCTAssertEqual(report.bridge.status?.eventKitRestartCount, 1)
        XCTAssertEqual(report.clientApprovals.approvedCount, 0)
        XCTAssertEqual(report.loginItem, "enabled")
        XCTAssertEqual(report.tunnel, .running)

        let json = try report.encodedJSON()
        XCTAssertFalse(json.contains(privateAddress))
        XCTAssertFalse(json.contains(privateTunnelID))
        XCTAssertFalse(json.contains(tunnelClient.path))
    }

    func testReportStaysUsefulWhenNothingIsRunning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = MacMCPDiagnosticCollector(
            launchConfigurationStore: AppLaunchConfigurationStore(fileURL: directory.appendingPathComponent("missing.json")),
            clientApprovalStore: ClientApprovalStore(fileURL: directory.appendingPathComponent("clients.json")),
            bridgeStatusRequest: { throw LocalBridgeIPCClientError.unavailable },
            loginItemStatus: { .notRegistered },
            tunnelHealthProbe: { _ in false }
        )

        let report = await collector.collect()
        XCTAssertEqual(report.configuration.availability, .notConfigured)
        XCTAssertEqual(report.bridge.availability, .unavailable)
        XCTAssertNil(report.bridge.status)
        XCTAssertEqual(report.clientApprovals.availability, .available)
        XCTAssertEqual(report.loginItem, "not_registered")
        XCTAssertEqual(report.tunnel, .notConfigured)

        let payload = try JSONSerialization.jsonObject(with: Data(report.encodedJSON().utf8)) as? [String: Any]
        let bridge = payload?["bridge"] as? [String: Any]
        XCTAssertTrue(bridge?["status"] is NSNull)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
