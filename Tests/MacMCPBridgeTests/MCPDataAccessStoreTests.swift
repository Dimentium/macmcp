import Foundation
import MCP
import XCTest
@testable import MacMCPBridge

final class MCPDataAccessStoreTests: XCTestCase {
    func testCalendarAndRemindersAreEnabledByDefaultAndPersist() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mcp-data-access.json")
        let store = MCPDataAccessStore(fileURL: fileURL)

        let calendarInitiallyEnabled = await store.isEnabled(.calendar)
        let remindersInitiallyEnabled = await store.isEnabled(.reminders)
        XCTAssertTrue(calendarInitiallyEnabled)
        XCTAssertTrue(remindersInitiallyEnabled)
        try await store.setEnabled(false, for: .calendar)

        let reloaded = MCPDataAccessStore(fileURL: fileURL)
        let calendarAfterReload = await reloaded.isEnabled(.calendar)
        let remindersAfterReload = await reloaded.isEnabled(.reminders)
        XCTAssertFalse(calendarAfterReload)
        XCTAssertTrue(remindersAfterReload)
    }

    func testCorruptStateFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mcp-data-access.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = MCPDataAccessStore(fileURL: fileURL)

        let calendarEnabled = await store.isEnabled(.calendar)
        let remindersEnabled = await store.isEnabled(.reminders)
        XCTAssertFalse(calendarEnabled)
        XCTAssertFalse(remindersEnabled)
    }

    func testControllerFiltersToolsAndReturnsStableDenial() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPDataAccessStore(fileURL: directory.appendingPathComponent("access.json"))
        let controller = MCPDataAccessController(store: store)
        try await controller.setEnabled(false, for: .calendar)
        let tools = [
            Tool(name: "bridge_status", description: "status", inputSchema: .object([:])),
            Tool(name: "calendar.list", description: "calendar", inputSchema: .object([:])),
            Tool(name: "reminders.list", description: "reminders", inputSchema: .object([:]))
        ]

        let filtered = await controller.filterTools(tools)
        XCTAssertEqual(filtered.map(\.name), ["bridge_status", "reminders.list"])
        let calendarDenial = await controller.deniedMessage(forToolName: "calendar.list")
        let mailDenial = await controller.deniedMessage(forToolName: "mail.search")
        XCTAssertEqual(calendarDenial, MCPDataCategory.calendar.disabledMessage)
        XCTAssertNil(mailDenial)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
