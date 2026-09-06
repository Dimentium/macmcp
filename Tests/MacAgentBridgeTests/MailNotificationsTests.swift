import Foundation
import XCTest
@testable import MacAgentBridge

final class MailNotificationsTests: XCTestCase {
    func testMonitorIsOptInAndSettingsArePrivate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mail-monitor.json")
        let store = MailMonitorSettingsStore(fileURL: fileURL)

        XCTAssertEqual(try store.read(), MailMonitorSettings(enabled: false))
        try store.save(MailMonitorSettings(enabled: true))
        XCTAssertEqual(try store.read(), MailMonitorSettings(enabled: true))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testNotificationCopyNeverReflectsMailContent() {
        let immediate = AttentionDecision(
            needsAttention: true,
            categories: [.paymentsSecurity],
            urgency: .immediate,
            reasonCode: .paymentOrSecurity,
            confidence: 0.9
        )
        let normal = AttentionDecision(
            needsAttention: true,
            categories: [.personal],
            urgency: .normal,
            reasonCode: .likelyHumanSender,
            confidence: 0.7
        )

        XCTAssertEqual(MacOSAttentionNotificationPoster.copy(for: immediate).title, "MacMCP Mail")
        XCTAssertEqual(
            MacOSAttentionNotificationPoster.copy(for: immediate).body,
            "A new message needs immediate attention."
        )
        XCTAssertEqual(
            MacOSAttentionNotificationPoster.copy(for: normal).body,
            "A new message needs attention."
        )
    }

    @MainActor
    func testMenuTitlesDescribeNotificationState() {
        XCTAssertEqual(MenuBarHost.mailNotificationTitle(state: .off), "⚪ Mail Notifications: off")
        XCTAssertEqual(MenuBarHost.mailNotificationTitle(state: .starting), "🟡 Mail Notifications: starting")
        XCTAssertEqual(MenuBarHost.mailNotificationTitle(state: .monitoring), "🟢 Mail Notifications: on")
        XCTAssertEqual(
            MenuBarHost.mailNotificationTitle(state: .needsPermission),
            "🟡 Mail Notifications: needs permission"
        )
        XCTAssertEqual(
            MenuBarHost.mailNotificationTitle(state: .unavailable),
            "🔴 Mail Notifications: unavailable"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
