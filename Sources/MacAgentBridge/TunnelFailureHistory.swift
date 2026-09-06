import Foundation

enum ChatGPTTunnelPhase: String, Codable, Equatable, Sendable {
    case prerequisites
    case credential
    case initialize
    case doctor
    case run
    case health

    var menuLabel: String {
        switch self {
        case .prerequisites:
            return "Prerequisites"
        case .credential:
            return "Credential"
        case .initialize:
            return "Initialize"
        case .doctor:
            return "Doctor"
        case .run:
            return "Run"
        case .health:
            return "Health"
        }
    }
}

enum ChatGPTTunnelFailureReason: String, Codable, Equatable, Sendable {
    case clientUnavailable = "client_unavailable"
    case ipcUnavailable = "ipc_unavailable"
    case credentialUnavailable = "credential_unavailable"
    case credentialMissing = "credential_missing"
    case proxySetupFailed = "proxy_setup_failed"
    case processLaunchFailed = "process_launch_failed"
    case processExited = "process_exited"
    case healthTimedOut = "health_timed_out"
    case healthUnavailable = "health_unavailable"

    var menuLabel: String {
        switch self {
        case .clientUnavailable:
            return "client unavailable"
        case .ipcUnavailable:
            return "local bridge unavailable"
        case .credentialUnavailable:
            return "credential unavailable"
        case .credentialMissing:
            return "credential missing"
        case .proxySetupFailed:
            return "proxy setup failed"
        case .processLaunchFailed:
            return "process launch failed"
        case .processExited:
            return "process exited"
        case .healthTimedOut:
            return "timed out"
        case .healthUnavailable:
            return "unavailable"
        }
    }
}

struct ChatGPTTunnelFailure: Codable, Equatable, Sendable {
    let occurredAt: String
    let phase: ChatGPTTunnelPhase
    let reason: ChatGPTTunnelFailureReason

    init(
        occurredAt: String,
        phase: ChatGPTTunnelPhase,
        reason: ChatGPTTunnelFailureReason
    ) {
        self.occurredAt = occurredAt
        self.phase = phase
        self.reason = reason
    }

    static func now(
        phase: ChatGPTTunnelPhase,
        reason: ChatGPTTunnelFailureReason,
        date: Date = Date()
    ) -> ChatGPTTunnelFailure {
        ChatGPTTunnelFailure(
            occurredAt: ISO8601DateFormatter().string(from: date),
            phase: phase,
            reason: reason
        )
    }

    var menuTitle: String {
        "\(phase.menuLabel): \(reason.menuLabel)"
    }
}

enum TunnelFailureHistoryStoreError: LocalizedError, Equatable {
    case corrupt
    case unableToPersist

    var errorDescription: String? {
        switch self {
        case .corrupt:
            return "Tunnel diagnostic history is corrupt"
        case .unableToPersist:
            return "Unable to persist tunnel diagnostic history"
        }
    }
}

struct TunnelFailureHistoryStore: Sendable {
    private struct Payload: Codable {
        let schemaVersion: Int
        let failures: [ChatGPTTunnelFailure]
    }

    let fileURL: URL
    let capacity: Int

    init(fileURL: URL = Self.defaultFileURL(), capacity: Int = 12) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
    }

    static func defaultFileURL() -> URL {
        LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mac-agent-bridge", isDirectory: true)
            .appendingPathComponent("tunnel-failures.json")
    }

    func read() throws -> [ChatGPTTunnelFailure] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1,
                  payload.failures.allSatisfy(isValid)
            else {
                throw TunnelFailureHistoryStoreError.corrupt
            }
            return Array(payload.failures.suffix(capacity))
        } catch let error as TunnelFailureHistoryStoreError {
            throw error
        } catch {
            throw TunnelFailureHistoryStoreError.corrupt
        }
    }

    func record(_ failure: ChatGPTTunnelFailure) throws {
        var failures = try read()
        failures.append(failure)
        try persist(Array(failures.suffix(capacity)))
    }

    private func persist(_ failures: [ChatGPTTunnelFailure]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Payload(schemaVersion: 1, failures: failures))
                .write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw TunnelFailureHistoryStoreError.unableToPersist
        }
    }

    private func isValid(_ failure: ChatGPTTunnelFailure) -> Bool {
        guard failure.occurredAt.utf8.count <= 32,
              !failure.occurredAt.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }
        return ISO8601DateFormatter().date(from: failure.occurredAt) != nil
    }
}
