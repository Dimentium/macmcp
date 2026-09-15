import Foundation
import MCP

enum MCPDataCategory: String, CaseIterable, Codable, Sendable {
    case calendar
    case reminders

    var title: String {
        switch self {
        case .calendar:
            return "Calendar"
        case .reminders:
            return "Reminders"
        }
    }

    var disabledMessage: String {
        "\(title) access is disabled. In MacMCP Settings, enable MCP access for \(title)."
    }

    static func forToolName(_ publicName: String) -> Self? {
        if publicName.hasPrefix("calendar.") { return .calendar }
        if publicName.hasPrefix("reminders.") { return .reminders }
        return nil
    }
}

enum EventKitWriteCapability: String, CaseIterable, Codable, Sendable {
    case calendarRecurrence
    case calendarAlarms
    case remindersRecurrence
    case remindersLocationTriggers

    var category: MCPDataCategory {
        switch self {
        case .calendarRecurrence, .calendarAlarms: .calendar
        case .remindersRecurrence, .remindersLocationTriggers: .reminders
        }
    }

    var title: String {
        switch self {
        case .calendarRecurrence, .remindersRecurrence: "Recurrence"
        case .calendarAlarms: "Alerts"
        case .remindersLocationTriggers: "Location triggers"
        }
    }

    static func required(forToolName publicName: String, arguments: [String: Value]?) -> Set<Self> {
        let argumentNames: Set<String> = arguments.map { Set($0.keys) } ?? []
        var capabilities: Set<Self> = []
        if publicName.hasPrefix("calendar.") {
            if argumentNames.contains("recurrence") || argumentNames.contains("clear_recurrence") {
                capabilities.insert(.calendarRecurrence)
            }
            if argumentNames.contains("alarms") {
                capabilities.insert(.calendarAlarms)
            }
        }
        if publicName == "reminders.create" {
            if argumentNames.contains("recurrence") {
                capabilities.insert(.remindersRecurrence)
            }
            if argumentNames.contains("location_trigger") {
                capabilities.insert(.remindersLocationTriggers)
            }
        }
        return capabilities
    }
}

enum MCPDataAccessError: LocalizedError, Equatable {
    case unableToPersist

    var errorDescription: String? {
        switch self {
        case .unableToPersist:
            return "Unable to persist MCP data access"
        }
    }
}

actor MCPDataAccessStore {
    private struct Payload: Codable {
        let schemaVersion: Int
        var enabledCategories: Set<MCPDataCategory>
        var writableCategories: Set<MCPDataCategory>
        var enabledWriteCapabilities: Set<EventKitWriteCapability>

        init(
            schemaVersion: Int,
            enabledCategories: Set<MCPDataCategory>,
            writableCategories: Set<MCPDataCategory> = [],
            enabledWriteCapabilities: Set<EventKitWriteCapability> = []
        ) {
            self.schemaVersion = schemaVersion
            self.enabledCategories = enabledCategories
            self.writableCategories = writableCategories
            self.enabledWriteCapabilities = enabledWriteCapabilities
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            enabledCategories = try container.decode(Set<MCPDataCategory>.self, forKey: .enabledCategories)
            writableCategories = try container.decodeIfPresent(Set<MCPDataCategory>.self, forKey: .writableCategories) ?? []
            enabledWriteCapabilities = try container.decodeIfPresent(
                Set<EventKitWriteCapability>.self,
                forKey: .enabledWriteCapabilities
            ) ?? []
        }
    }

    private let fileURL: URL

    init(fileURL: URL = MCPDataAccessStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("mcp-data-access.json")
    }

    func enabledCategories() -> Set<MCPDataCategory> {
        (try? load().enabledCategories) ?? []
    }

    func isEnabled(_ category: MCPDataCategory) -> Bool {
        enabledCategories().contains(category)
    }

    func isWritable(_ category: MCPDataCategory) -> Bool {
        (try? load().writableCategories.contains(category)) ?? false
    }

    func writableCategories() -> Set<MCPDataCategory> {
        (try? load().writableCategories) ?? []
    }

    func enabledWriteCapabilities() -> Set<EventKitWriteCapability> {
        (try? load().enabledWriteCapabilities) ?? []
    }

    func setEnabled(_ enabled: Bool, for category: MCPDataCategory) throws {
        var payload = try load()
        if enabled {
            payload.enabledCategories.insert(category)
        } else {
            payload.enabledCategories.remove(category)
        }
        try save(payload)
    }

    func setWritable(_ writable: Bool, for category: MCPDataCategory) throws {
        var payload = try load()
        if writable {
            payload.writableCategories.insert(category)
        } else {
            payload.writableCategories.remove(category)
        }
        try save(payload)
    }

    func setWriteCapability(_ enabled: Bool, capability: EventKitWriteCapability) throws {
        var payload = try load()
        if enabled {
            payload.enabledWriteCapabilities.insert(capability)
        } else {
            payload.enabledWriteCapabilities.remove(capability)
        }
        try save(payload)
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, enabledCategories: Set(MCPDataCategory.allCases))
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1 else {
                return Payload(schemaVersion: 1, enabledCategories: [])
            }
            return payload
        } catch {
            // A corrupt or incompatible state file must never expose personal
            // data until the user explicitly enables the categories again.
            return Payload(schemaVersion: 1, enabledCategories: [])
        }
    }

    private func save(_ payload: Payload) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw MCPDataAccessError.unableToPersist
        }
    }
}

actor MCPDataAccessController {
    private let store: MCPDataAccessStore

    init(store: MCPDataAccessStore = MCPDataAccessStore()) {
        self.store = store
    }

    func enabledCategories() async -> Set<MCPDataCategory> {
        await store.enabledCategories()
    }

    func isEnabled(_ category: MCPDataCategory) async -> Bool {
        await store.isEnabled(category)
    }

    func isEnabled(forToolName publicName: String) async -> Bool {
        guard let category = MCPDataCategory.forToolName(publicName) else { return true }
        return await isEnabled(category)
    }

    func isWritable(_ category: MCPDataCategory) async -> Bool {
        await store.isWritable(category)
    }

    func writableCategories() async -> Set<MCPDataCategory> {
        await store.writableCategories()
    }

    func enabledWriteCapabilities() async -> Set<EventKitWriteCapability> {
        await store.enabledWriteCapabilities()
    }

    func setWritable(_ writable: Bool, for category: MCPDataCategory) async throws {
        try await store.setWritable(writable, for: category)
    }

    func setWriteCapability(_ enabled: Bool, capability: EventKitWriteCapability) async throws {
        try await store.setWriteCapability(enabled, capability: capability)
    }

    func setEnabled(_ enabled: Bool, for category: MCPDataCategory) async throws {
        try await store.setEnabled(enabled, for: category)
    }

    func filterTools(_ tools: [Tool]) async -> [Tool] {
        let enabled = await enabledCategories()
        let writable = await writableCategories()
        return tools.filter { tool in
            guard let category = MCPDataCategory.forToolName(tool.name) else { return true }
            guard enabled.contains(category) else { return false }
            return !ReaderPolicy.eventKitActionToolNames.contains(tool.name) || writable.contains(category)
        }
    }

    func deniedMessage(forToolName publicName: String, arguments: [String: Value]? = nil) async -> String? {
        guard let category = MCPDataCategory.forToolName(publicName) else { return nil }
        guard await isEnabled(category) else { return category.disabledMessage }
        guard ReaderPolicy.eventKitActionToolNames.contains(publicName) else { return nil }
        guard await isWritable(category) else {
            return "\(category.title) write access is disabled. In MacMCP Settings, open \(category.title) and enable Write access."
        }
        let enabledCapabilities = await enabledWriteCapabilities()
        let requiredCapabilities = EventKitWriteCapability.required(
            forToolName: publicName,
            arguments: arguments
        )
        guard let missing = requiredCapabilities.first(where: { !enabledCapabilities.contains($0) }) else {
            return nil
        }
        return "\(missing.title) access is disabled. In MacMCP Settings, open \(category.title) and enable \(missing.title)."
    }
}
