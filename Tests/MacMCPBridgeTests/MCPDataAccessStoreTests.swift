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
        let calendarInitiallyWritable = await store.isWritable(.calendar)
        let remindersInitiallyWritable = await store.isWritable(.reminders)
        XCTAssertTrue(calendarInitiallyEnabled)
        XCTAssertTrue(remindersInitiallyEnabled)
        XCTAssertFalse(calendarInitiallyWritable)
        XCTAssertFalse(remindersInitiallyWritable)
        try await store.setEnabled(false, for: .calendar)
        try await store.setWritable(true, for: .reminders)
        try await store.setWriteCapability(true, capability: .calendarAlarms)

        let reloaded = MCPDataAccessStore(fileURL: fileURL)
        let calendarAfterReload = await reloaded.isEnabled(.calendar)
        let remindersAfterReload = await reloaded.isEnabled(.reminders)
        let remindersWritableAfterReload = await reloaded.isWritable(.reminders)
        let enabledCapabilitiesAfterReload = await reloaded.enabledWriteCapabilities()
        XCTAssertFalse(calendarAfterReload)
        XCTAssertTrue(remindersAfterReload)
        XCTAssertTrue(remindersWritableAfterReload)
        XCTAssertEqual(enabledCapabilitiesAfterReload, [.calendarAlarms])
    }

    func testLegacyReadAccessStateKeepsEventKitWritesDisabled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mcp-data-access.json")
        try Data(#"{"enabledCategories":["calendar","reminders"],"schemaVersion":1}"#.utf8)
            .write(to: fileURL)

        let store = MCPDataAccessStore(fileURL: fileURL)
        let calendarEnabled = await store.isEnabled(.calendar)
        let remindersEnabled = await store.isEnabled(.reminders)
        let calendarWritable = await store.isWritable(.calendar)
        let remindersWritable = await store.isWritable(.reminders)
        XCTAssertTrue(calendarEnabled)
        XCTAssertTrue(remindersEnabled)
        XCTAssertFalse(calendarWritable)
        XCTAssertFalse(remindersWritable)
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

    func testEventKitActionsAreHiddenAndDeniedUntilWriteAccessIsEnabled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MCPDataAccessController(
            store: MCPDataAccessStore(fileURL: directory.appendingPathComponent("access.json"))
        )
        let tools = [
            Tool(name: "calendar.list", description: "calendar", inputSchema: .object([:])),
            Tool(name: "calendar.create", description: "create", inputSchema: .object([:])),
            Tool(name: "reminders.complete", description: "complete", inputSchema: .object([:]))
        ]

        let initiallyVisible = await controller.filterTools(tools).map(\.name)
        let initialDenial = await controller.deniedMessage(forToolName: "calendar.create")
        XCTAssertEqual(initiallyVisible, ["calendar.list"])
        XCTAssertEqual(
            initialDenial,
            "Calendar write access is disabled. In MacMCP Settings, open Calendar and enable Write access."
        )

        try await controller.setWritable(true, for: .calendar)
        let visibleWithWrites = await controller.filterTools(tools).map(\.name)
        let denialWithWrites = await controller.deniedMessage(forToolName: "calendar.create")
        XCTAssertEqual(
            visibleWithWrites,
            ["calendar.list", "calendar.create"]
        )
        XCTAssertNil(denialWithWrites)
    }

    func testAdvancedEventKitCapabilitiesRemainOffUntilIndividuallyEnabled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MCPDataAccessController(
            store: MCPDataAccessStore(fileURL: directory.appendingPathComponent("access.json"))
        )
        try await controller.setWritable(true, for: .calendar)
        try await controller.setWritable(true, for: .reminders)

        let recurrenceDenied = await controller.deniedMessage(
            forToolName: "calendar.create",
            arguments: ["recurrence": .string("weekly")]
        )
        let alarmsDenied = await controller.deniedMessage(
            forToolName: "calendar.update",
            arguments: ["alarms": .array([])]
        )
        let locationDenied = await controller.deniedMessage(
            forToolName: "reminders.create",
            arguments: ["location_trigger": .object([:])]
        )
        XCTAssertEqual(recurrenceDenied, "Recurrence access is disabled. In MacMCP Settings, open Calendar and enable Recurrence.")
        XCTAssertEqual(alarmsDenied, "Alerts access is disabled. In MacMCP Settings, open Calendar and enable Alerts.")
        XCTAssertEqual(locationDenied, "Location triggers access is disabled. In MacMCP Settings, open Reminders and enable Location triggers.")

        try await controller.setWriteCapability(true, capability: .calendarRecurrence)
        try await controller.setWriteCapability(true, capability: .calendarAlarms)
        try await controller.setWriteCapability(true, capability: .remindersLocationTriggers)
        let recurrenceAllowed = await controller.deniedMessage(
            forToolName: "calendar.create",
            arguments: ["recurrence": .string("weekly")]
        )
        let alarmsAllowed = await controller.deniedMessage(
            forToolName: "calendar.update",
            arguments: ["alarms": .array([])]
        )
        let locationAllowed = await controller.deniedMessage(
            forToolName: "reminders.create",
            arguments: ["location_trigger": .object([:])]
        )
        XCTAssertNil(recurrenceAllowed)
        XCTAssertNil(alarmsAllowed)
        XCTAssertNil(locationAllowed)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
