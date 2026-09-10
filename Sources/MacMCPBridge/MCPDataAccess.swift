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
        "(title) access is disabled. In the MacMCP menu, open (title) and enable Allow MCP access."
    }

    static func forToolName(_ publicName: String) -> Self? {
        if publicName.hasPrefix("calendar.") { return .calendar }
        if publicName.hasPrefix("reminders.") { return .reminders }
        return nil
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

    func setEnabled(_ enabled: Bool, for category: MCPDataCategory) throws {
        var payload = try load()
        if enabled {
            payload.enabledCategories.insert(category)
        } else {
            payload.enabledCategories.remove(category)
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

    func setEnabled(_ enabled: Bool, for category: MCPDataCategory) async throws {
        try await store.setEnabled(enabled, for: category)
    }

    func filterTools(_ tools: [Tool]) async -> [Tool] {
        let enabled = await enabledCategories()
        return tools.filter { tool in
            guard let category = MCPDataCategory.forToolName(tool.name) else { return true }
            return enabled.contains(category)
        }
    }

    func deniedMessage(forToolName publicName: String) async -> String? {
        guard let category = MCPDataCategory.forToolName(publicName),
              !(await isEnabled(category))
        else { return nil }
        return category.disabledMessage
    }
}
