import Foundation

actor MailAccountAccessStore {
    private struct Payload: Codable {
        let schemaVersion: Int
        var disabledAccountIDs: Set<String>
    }

    private let fileURL: URL

    init(fileURL: URL = MailAccountAccessStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("mail-account-access.json")
    }

    func enabledAccountIDs(for configuredAccountIDs: Set<String>) -> Set<String> {
        guard let payload = try? load() else {
            return configuredAccountIDs
        }
        return configuredAccountIDs.subtracting(payload.disabledAccountIDs)
    }

    func setEnabled(_ enabled: Bool, for accountID: String) throws {
        var payload = try load()
        if enabled {
            payload.disabledAccountIDs.remove(accountID)
        } else {
            payload.disabledAccountIDs.insert(accountID)
        }
        try save(payload)
    }

    func remove(accountID: String) throws {
        var payload = try load()
        payload.disabledAccountIDs.remove(accountID)
        try save(payload)
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, disabledAccountIDs: [])
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        guard payload.schemaVersion == 1 else {
            throw MailAccountAccessStoreError.incompatibleState
        }
        return payload
    }

    private func save(_ payload: Payload) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw MailAccountAccessStoreError.unableToPersist
        }
    }
}

private enum MailAccountAccessStoreError: Error {
    case incompatibleState
    case unableToPersist
}
