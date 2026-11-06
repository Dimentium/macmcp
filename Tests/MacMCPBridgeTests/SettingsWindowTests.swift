import Foundation
import XCTest
@testable import MacMCPBridge

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testTunnelStateUpdatesVisibleStatus() {
        let model = SettingsWindowModel()

        model.updateTunnelState(.starting)
        XCTAssertEqual(model.tunnelStatus, "Starting")
        model.updateTunnelState(.running)
        XCTAssertEqual(model.tunnelStatus, "Connected")
        model.updateTunnelState(.unavailable)
        XCTAssertEqual(model.tunnelStatus, "Unavailable")
    }

    func testSettingsSheetsHaveDistinctSingleSelection() {
        let model = SettingsWindowModel()

        model.activeSheet = .tunnel
        XCTAssertEqual(model.activeSheet, .tunnel)
        model.activeSheet = .mailAccount("icloud-person@example.com")
        XCTAssertEqual(model.activeSheet, .mailAccount("icloud-person@example.com"))
        XCTAssertNotEqual(
            SettingsWindowModel.Sheet.tunnel.id,
            SettingsWindowModel.Sheet.calendar.id
        )
    }

    func testTunnelClientVersionReaderLoadsExecutableVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-tunnel-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("tunnel-client")
        let script = "#!/bin/sh\nprintf 'tunnel-client 1.2.3\\n'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            TunnelClientVersionReader.version(atPath: executable.path),
            "tunnel-client 1.2.3"
        )
    }

    func testLocalBridgeStateUpdatesVisibleStatus() {
        let model = SettingsWindowModel()

        model.updateLocalBridgeState(isRunning: false)
        XCTAssertEqual(model.localBridgeStatus, "Starting")
        XCTAssertFalse(model.localBridgeEnabled)
        model.updateLocalBridgeState(isRunning: true)
        XCTAssertEqual(model.localBridgeStatus, "Running")
        XCTAssertTrue(model.localBridgeEnabled)
    }

    func testMailAccountDisplayNameAddsHostOnlyForUsernameWithoutAt() {
        let model = SettingsWindowModel()
        model.mailAccounts = [
            SettingsWindowModel.MailAccount(
                id: "imap",
                provider: "Other IMAP",
                address: "alex",
                imapHost: "imap.example.com",
                imapPort: 993,
                imapSecurity: .tls,
                enabled: true,
                readOnly: true,
                hasPassword: true
            )
        ]

        XCTAssertEqual(model.mailAccounts[0].displayName, "alex · imap.example.com")
    }

    func testAccessMutatorsPublishTheRequestedActions() {
        let model = SettingsWindowModel()
        var launchValue: Bool?
        var tunnelValue: Bool?
        var calendarValue: Bool?
        var calendarWriteValue: Bool?
        var remindersWriteValue: Bool?
        var writeCapabilityValue: (EventKitWriteCapability, Bool)?
        var mailValue: (String, Bool)?
        model.onLaunchAtLoginChanged = { launchValue = $0 }
        model.onTunnelChanged = { tunnelValue = $0 }
        model.onCalendarChanged = { calendarValue = $0 }
        model.onCalendarWriteAccessChanged = { calendarWriteValue = $0 }
        model.onRemindersWriteAccessChanged = { remindersWriteValue = $0 }
        model.onEventKitWriteCapabilityChanged = { writeCapabilityValue = ($0, $1) }
        model.onMailAccountChanged = { mailValue = ($0, $1) }
        model.mailAccounts = [
            SettingsWindowModel.MailAccount(
                id: "gmail",
                provider: "Gmail",
                address: "person@gmail.com",
                imapHost: "imap.gmail.com",
                imapPort: 993,
                imapSecurity: .tls,
                enabled: true,
                readOnly: true,
                hasPassword: true
            )
        ]

        model.setLaunchAtLogin(true)
        model.setTunnelEnabled(false)
        model.setCalendarAccess(false)
        model.setCalendarWriteAccess(true)
        model.setRemindersWriteAccess(true)
        model.setWriteCapability(.calendarAlarms, enabled: true)
        model.setMailAccountEnabled(id: "gmail", enabled: false)

        XCTAssertEqual(launchValue, true)
        XCTAssertEqual(tunnelValue, false)
        XCTAssertEqual(calendarValue, false)
        XCTAssertEqual(calendarWriteValue, true)
        XCTAssertEqual(remindersWriteValue, true)
        XCTAssertFalse(model.calendarReadOnly)
        XCTAssertFalse(model.remindersReadOnly)
        XCTAssertEqual(writeCapabilityValue?.0, .calendarAlarms)
        XCTAssertEqual(writeCapabilityValue?.1, true)
        XCTAssertTrue(model.calendarAlarmsEnabled)
        XCTAssertEqual(mailValue?.0, "gmail")
        XCTAssertEqual(mailValue?.1, false)
        XCTAssertFalse(model.mailAccounts[0].enabled)
    }

    func testUnknownMailAccountDoesNotInvokeTheToggleAction() {
        let model = SettingsWindowModel()
        var invoked = false
        model.onMailAccountChanged = { _, _ in invoked = true }

        model.setMailAccountEnabled(id: "missing", enabled: false)

        XCTAssertFalse(invoked)
    }
}
