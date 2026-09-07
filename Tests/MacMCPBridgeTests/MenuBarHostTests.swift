import AppKit
import XCTest
@testable import MacMCPBridge

private actor BlockedProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isUnblocked = false

    func wait() async {
        guard !isUnblocked else { return }
        isBlocked = true
        waitingContinuation?.resume()
        waitingContinuation = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            self.waitingContinuation = continuation
        }
    }

    func unblock() {
        isUnblocked = true
        continuation?.resume()
        continuation = nil
        waitingContinuation?.resume()
        waitingContinuation = nil
    }
}

private final class FakeLoginItemController: LoginItemControlling {
    var status: LoginItemStatus
    private(set) var registerCallCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }
}

@MainActor
final class MenuBarHostTests: XCTestCase {
    func testQuitMenuItemTargetsHost() {
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            )
        )
        let statusItems = MenuBarHost.StatusMenuItems()
        let menu = host.makeMenu(statusItems: statusItems)

        let quitItem = menu.items.last
        XCTAssertTrue(menu.delegate === host)
        XCTAssertEqual(menu.items.prefix(4).map(\.isEnabled), [false, true, false, false])
        XCTAssertEqual(menu.items[0], statusItems.overall)
        XCTAssertEqual(menu.items[1], statusItems.mail)
        XCTAssertEqual(menu.items[2], statusItems.calendar)
        XCTAssertEqual(menu.items[3], statusItems.reminders)
        XCTAssertEqual(menu.items[4], statusItems.notifications)
        XCTAssertEqual(menu.items[5], statusItems.loginItem)
        XCTAssertEqual(menu.items[6], statusItems.tunnel)
        XCTAssertEqual(menu.items[7], statusItems.clients)
        XCTAssertTrue(menu.items[4].isEnabled)
        XCTAssertFalse(menu.items[5].isEnabled)
        XCTAssertTrue(menu.items[6].isEnabled)
        XCTAssertNotNil(menu.items[6].submenu)
        XCTAssertTrue(menu.items[7].isEnabled)
        XCTAssertEqual(quitItem?.title, "Quit")
        XCTAssertTrue(quitItem?.target === host)
        XCTAssertEqual(quitItem?.action, #selector(MenuBarHost.quit))
    }

    func testStatusMenuTitlesUseMacMCPAndComponentCircles() {
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: URL(fileURLWithPath: "/opt/mail-mcp"),
                eventKitSidecarURL: URL(fileURLWithPath: "/opt/CheICalMCP"),
                iCloudAddress: "reader@example.invalid",
                menuBar: true
            )
        )
        let statusItems = MenuBarHost.StatusMenuItems()
        host.updateStatusMenu(
            statusItems,
            snapshot: BridgeStatus(
                version: AppVersion.version,
                mode: .reader,
                mail: .ready,
                calendar: .connectedUnverified,
                reminders: .unavailable,
                mailRestartCount: 0,
                eventKitRestartCount: 0,
                writeCapabilitiesEnabled: false
            )
        )

        XCTAssertEqual(statusItems.overall.title, "🔴 MacMCP: needs attention")
        XCTAssertEqual(statusItems.mail.title, "🟢 Mail: ready")
        XCTAssertEqual(statusItems.calendar.title, "🟡 Calendar: checking")
        XCTAssertEqual(statusItems.reminders.title, "🔴 Reminders: unavailable")
    }

    func testComponentStatusMarkerMapping() {
        XCTAssertEqual(MenuBarHost.componentTitle("Mail", state: .ready), "🟢 Mail: ready")
        XCTAssertEqual(MenuBarHost.componentTitle("Calendar", state: .connectedUnverified), "🟡 Calendar: checking")
        XCTAssertEqual(MenuBarHost.componentTitle("Reminders", state: .unavailable), "🔴 Reminders: unavailable")
        XCTAssertEqual(MenuBarHost.componentTitle("Mail", state: .notConfigured), "⚪ Mail: not configured")
    }

    func testMailMenuShowsPerAccountReadOnlyControls() throws {
        let accounts = [
            try MailAccountConfiguration.iCloud(address: "icloud@example.invalid"),
            try MailAccountConfiguration.gmail(address: "gmail@example.invalid")
        ]
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: URL(fileURLWithPath: "/opt/mail-mcp"),
                eventKitSidecarURL: nil,
                mailAccounts: accounts,
                menuBar: true
            )
        )
        let item = NSMenuItem(title: "Mail", action: nil, keyEquivalent: "")

        host.updateMailAccountsMenu(item, writableAccountIDs: ["gmail"])

        XCTAssertEqual(item.submenu?.items.map(\.title), ["icloud@example.invalid", "gmail@example.invalid"])
        XCTAssertEqual(item.submenu?.items[0].submenu?.items.first?.title, "Read only")
        XCTAssertEqual(item.submenu?.items[0].submenu?.items.first?.state, .on)
        XCTAssertEqual(item.submenu?.items[1].submenu?.items.first?.state, .off)
    }

    func testLoginItemStatusTitlesUseCircles() {
        XCTAssertEqual(MenuBarHost.loginItemTitle(status: .enabled), "🟢 Launch at Login: enabled")
        XCTAssertEqual(MenuBarHost.loginItemTitle(status: .notRegistered), "⚪ Launch at Login: not registered")
        XCTAssertEqual(MenuBarHost.loginItemTitle(status: .requiresApproval), "🟡 Launch at Login: needs approval")
        XCTAssertEqual(MenuBarHost.loginItemTitle(status: .notFound), "🔴 Launch at Login: not found")
    }

    func testChatGPTTunnelStatusTitlesUseCircles() {
        XCTAssertEqual(
            MenuBarHost.chatGPTTunnelTitle(state: nil),
            "⚪ ChatGPT Tunnel: not configured"
        )
        XCTAssertEqual(
            MenuBarHost.chatGPTTunnelTitle(state: .starting),
            "🟡 ChatGPT Tunnel: starting"
        )
        XCTAssertEqual(
            MenuBarHost.chatGPTTunnelTitle(state: .running),
            "🟢 ChatGPT Tunnel: running"
        )
        XCTAssertEqual(
            MenuBarHost.chatGPTTunnelTitle(state: .unavailable),
            "🔴 ChatGPT Tunnel: unavailable"
        )
    }

    func testTunnelMenuShowsLatestRedactedFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TunnelFailureHistoryStore(fileURL: directory.appendingPathComponent("tunnel-failures.json"))
        try history.record(.init(
            occurredAt: "2026-09-06T10:00:00Z",
            phase: .health,
            reason: .healthTimedOut
        ))
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            ),
            tunnelFailureHistoryStore: history
        )
        let menu = host.makeMenu(statusItems: .init())

        XCTAssertEqual(
            menu.items[6].submenu?.items.first?.title,
            "Last failure: 2026-09-06T10:00:00Z Health: timed out"
        )
        XCTAssertFalse(menu.items[6].submenu?.items.first?.isEnabled ?? true)
    }

    func testClientsMenuShowsPendingAndApprovedClients() {
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            )
        )
        let item = NSMenuItem()
        let approved = ApprovedClient(
            fingerprint: "fingerprint",
            displayName: "Codex",
            identity: LocalClientIdentity(uid: 501, executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"),
            approvedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2)
        )
        let pending = LocalClientIdentity(uid: 501, executablePath: "/usr/local/bin/other-client")

        host.updateClientsMenu(item, snapshot: ClientApprovalSnapshot(approved: [approved], pending: pending))

        XCTAssertEqual(item.title, "🟡 Clients: approval needed")
        XCTAssertEqual(item.submenu?.items.first?.title, "Approve: other-client")
        XCTAssertEqual(item.submenu?.items.last?.title, "Revoke: Codex")
        XCTAssertEqual(item.submenu?.items.last?.representedObject as? String, "fingerprint")
    }

    func testClientPresentationNamesSeparateLocalAndTunnelProxies() {
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: URL(fileURLWithPath: "/opt/macmcp/libexec/mail-mcp"),
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            )
        )
        let localProxy = LocalClientIdentity(
            uid: 501,
            executablePath: "/opt/macmcp/bin/macmcp-bridge"
        )
        let otherClient = LocalClientIdentity(uid: 501, executablePath: "/usr/local/bin/other-client")

        XCTAssertEqual(host.clientPresentationName(identity: localProxy), "Local MCP Proxy")
        XCTAssertEqual(host.clientPresentationName(identity: otherClient), "other-client")
    }

    func testClientsMenuShowsEmptyState() {
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            )
        )
        let item = NSMenuItem()

        host.updateClientsMenu(item, snapshot: ClientApprovalSnapshot(approved: [], pending: nil))

        XCTAssertEqual(item.title, "⚪ Clients: none approved")
        XCTAssertEqual(item.submenu?.items.first?.title, "Approved: none")
        XCTAssertFalse(item.submenu?.items.first?.isEnabled ?? true)
    }

    func testLaunchConfigCanAutoRegisterLoginItem() throws {
        let configURL = try temporaryLaunchConfig()
        try """
        {
          "schemaVersion": 1,
          "launchAtLogin": true,
          "args": []
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let controller = FakeLoginItemController(status: .notRegistered)
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            ),
            launchConfigurationStore: AppLaunchConfigurationStore(fileURL: configURL),
            loginItemController: controller
        )
        let item = NSMenuItem()

        host.configureLaunchAtLogin(item)

        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertEqual(item.title, "🟢 Launch at Login: enabled")
    }

    func testLaunchConfigReRegistersLoginItemAfterAppReplacement() throws {
        let configURL = try temporaryLaunchConfig()
        try """
        {
          "schemaVersion": 1,
          "launchAtLogin": true,
          "args": []
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let controller = FakeLoginItemController(status: .notFound)
        let host = MenuBarHost(
            configuration: BridgeLaunchConfiguration(
                mailSidecarURL: nil,
                eventKitSidecarURL: nil,
                iCloudAddress: nil,
                menuBar: true
            ),
            launchConfigurationStore: AppLaunchConfigurationStore(fileURL: configURL),
            loginItemController: controller
        )
        let item = NSMenuItem()

        host.configureLaunchAtLogin(item)

        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertEqual(item.title, "🟢 Launch at Login: enabled")
    }

    func testProbeTimeoutRunsCleanupAndReturnsNearDeadline() async throws {
        let blocked = BlockedProbe()
        let started = Date()

        let timeoutTask = Task {
            try await EventKitHealthProber.withTimeout(
                nanoseconds: 100_000_000,
                onTimeout: { await blocked.unblock() },
                operation: {
                    await blocked.wait()
                    return true
                }
            )
        }
        await blocked.waitUntilBlocked()

        do {
            _ = try await timeoutTask.value
            XCTFail("Expected timeout")
        } catch let error as EventKitHealthProbeError {
            XCTAssertEqual(error, .timedOut)
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.08)
        XCTAssertLessThan(elapsed, 1.0)
    }

    private func temporaryLaunchConfig() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("launch.json")
    }
}
