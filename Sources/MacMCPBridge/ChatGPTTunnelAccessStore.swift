import Foundation

actor ChatGPTTunnelAccessStore {
    private struct Payload: Codable {
        let schemaVersion: Int
        let enabled: Bool
    }

    private let fileURL: URL

    init(fileURL: URL = ChatGPTTunnelAccessStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("chatgpt-tunnel-access.json")
    }

    func isEnabled() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        return (try? load().enabled) ?? false
    }

    func setEnabled(_ enabled: Bool) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
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
            try encoder.encode(Payload(schemaVersion: 1, enabled: enabled))
                .write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ChatGPTTunnelAccessStoreError.unableToPersist
        }
    }

    func reset() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() throws -> Payload {
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        guard payload.schemaVersion == 1 else {
            throw ChatGPTTunnelAccessStoreError.incompatibleState
        }
        return payload
    }
}

private enum ChatGPTTunnelAccessStoreError: Error {
    case incompatibleState
    case unableToPersist
}
