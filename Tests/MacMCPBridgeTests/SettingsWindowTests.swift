import Foundation
import XCTest
@testable import MacMCPBridge

@MainActor
final class SettingsWindowTests: XCTestCase {
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
        var mailValue: (String, Bool)?
        model.onLaunchAtLoginChanged = { launchValue = $0 }
        model.onTunnelChanged = { tunnelValue = $0 }
        model.onCalendarChanged = { calendarValue = $0 }
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
        model.setMailAccountEnabled(id: "gmail", enabled: false)

        XCTAssertEqual(launchValue, true)
        XCTAssertEqual(tunnelValue, false)
        XCTAssertEqual(calendarValue, false)
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
