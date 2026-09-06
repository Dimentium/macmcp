import Foundation
import MCP

enum MailActionAccessError: LocalizedError, Equatable {
    case unableToPersist

    var errorDescription: String? {
        switch self {
        case .unableToPersist:
            return "Unable to persist mail action access"
        }
    }
}

actor MailActionAccessStore {
    private struct Payload: Codable {
        let schemaVersion: Int
        var writableAccountIDs: Set<String>
    }

    private let fileURL: URL

    init(fileURL: URL = MailActionAccessStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mac-agent-bridge", isDirectory: true)
            .appendingPathComponent("mail-action-access.json")
    }

    func writableAccountIDs() -> Set<String> {
        (try? load().writableAccountIDs) ?? []
    }

    func isWritable(accountID: String) -> Bool {
        writableAccountIDs().contains(accountID)
    }

    func setReadOnly(_ readOnly: Bool, for accountID: String) throws {
        var payload = try load()
        if readOnly {
            payload.writableAccountIDs.remove(accountID)
        } else {
            payload.writableAccountIDs.insert(accountID)
        }
        try save(payload)
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, writableAccountIDs: [])
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1 else {
                return Payload(schemaVersion: 1, writableAccountIDs: [])
            }
            return payload
        } catch {
            // A missing, corrupt, or incompatible state file must never enable
            // mail mutations. The menu can replace it after an explicit toggle.
            return Payload(schemaVersion: 1, writableAccountIDs: [])
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
            throw MailActionAccessError.unableToPersist
        }
    }
}

actor MailActionAccessController {
    static let disabledMessage = "Mail actions are disabled for this account. In the MacMCP menu, open Mail > account and clear Read only."

    private let configuredAccountIDs: Set<String>
    private let store: MailActionAccessStore

    init(accounts: [MailAccountConfiguration], store: MailActionAccessStore = MailActionAccessStore()) {
        configuredAccountIDs = Set(accounts.map(\.id))
        self.store = store
    }

    func deniedMessage(for publicName: String, arguments: [String: Value]?) async -> String? {
        guard ReaderPolicy.mailActionToolNames.contains(publicName),
              let accountID = accountID(for: publicName, arguments: arguments),
              configuredAccountIDs.contains(accountID)
        else {
            return ReaderPolicy.mailActionToolNames.contains(publicName) ? Self.disabledMessage : nil
        }
        return await store.isWritable(accountID: accountID) ? nil : Self.disabledMessage
    }

    func writableAccountIDs() async -> Set<String> {
        (await store.writableAccountIDs()).intersection(configuredAccountIDs)
    }

    func setReadOnly(_ readOnly: Bool, for accountID: String) async throws {
        guard configuredAccountIDs.contains(accountID) else { return }
        try await store.setReadOnly(readOnly, for: accountID)
    }

    private func accountID(for publicName: String, arguments: [String: Value]?) -> String? {
        switch publicName {
        case "mail.create_managed_draft":
            return arguments?["account_id"]?.stringValue
        case "mail.update_managed_draft", "mail.mark":
            guard let opaqueMessageID = arguments?["message_id"]?.stringValue else {
                return nil
            }
            return try? MessageHandle(opaqueValue: opaqueMessageID).account
        default:
            return nil
        }
    }
}
