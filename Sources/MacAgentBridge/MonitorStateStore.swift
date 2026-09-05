import Foundation

struct MailboxCheckpoint: Codable, Equatable, Sendable {
    let account: String
    let mailbox: String
    let uidValidity: UInt32
    let highestUID: UInt32
}

struct NotificationRecord: Codable, Equatable, Sendable {
    let urgency: AttentionUrgency
}

struct MonitorState: Codable, Equatable, Sendable {
    var checkpoints: [String: MailboxCheckpoint] = [:]
    var notifications: [String: NotificationRecord] = [:]
}

struct MonitorObservation: Equatable, Sendable {
    let shouldNotify: Bool
    let uidValidityChanged: Bool
}

enum MonitorStateStoreError: LocalizedError, Equatable {
    case corruptState
    case unableToPersist

    var errorDescription: String? {
        switch self {
        case .corruptState:
            return "Monitor state is corrupt; refusing to overwrite it"
        case .unableToPersist:
            return "Unable to persist monitor state"
        }
    }
}

actor MonitorStateStore {
    private let fileURL: URL
    private var state: MonitorState

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                state = try JSONDecoder().decode(
                    MonitorState.self,
                    from: Data(contentsOf: fileURL)
                )
            } catch {
                throw MonitorStateStoreError.corruptState
            }
        } else {
            state = MonitorState()
        }
    }

    func observe(
        opaqueMessageID: String,
        decision: AttentionDecision
    ) throws -> MonitorObservation {
        let handle = try MessageHandle(opaqueValue: opaqueMessageID)
        let previousCheckpoint = state.checkpoints[handle.checkpointKey]
        let validityChanged = previousCheckpoint.map { $0.uidValidity != handle.uidValidity } ?? false

        let highestUID: UInt32
        if validityChanged {
            highestUID = handle.uid
        } else {
            highestUID = max(previousCheckpoint?.highestUID ?? 0, handle.uid)
        }
        state.checkpoints[handle.checkpointKey] = MailboxCheckpoint(
            account: handle.account,
            mailbox: handle.mailbox,
            uidValidity: handle.uidValidity,
            highestUID: highestUID
        )

        let previousNotification = state.notifications[opaqueMessageID]
        let shouldNotify = decision.needsAttention &&
            (previousNotification == nil || previousNotification?.urgency != decision.urgency)
        if decision.needsAttention {
            state.notifications[opaqueMessageID] = NotificationRecord(urgency: decision.urgency)
        }

        try persist()
        return MonitorObservation(
            shouldNotify: shouldNotify,
            uidValidityChanged: validityChanged
        )
    }

    func shouldProcess(_ handle: MessageHandle) -> Bool {
        guard let checkpoint = state.checkpoints[handle.checkpointKey] else { return true }
        return checkpoint.uidValidity != handle.uidValidity || handle.uid > checkpoint.highestUID
    }

    func shouldNotify(opaqueMessageID: String, decision: AttentionDecision) -> Bool {
        guard decision.needsAttention else { return false }
        guard let previous = state.notifications[opaqueMessageID] else { return true }
        return previous.urgency != decision.urgency
    }

    func establishBaseline(_ handles: [MessageHandle]) throws {
        for handle in handles {
            let previous = state.checkpoints[handle.checkpointKey]
            if let previous,
               previous.uidValidity == handle.uidValidity,
               previous.highestUID >= handle.uid {
                continue
            }
            state.checkpoints[handle.checkpointKey] = MailboxCheckpoint(
                account: handle.account,
                mailbox: handle.mailbox,
                uidValidity: handle.uidValidity,
                highestUID: handle.uid
            )
        }
        try persist()
    }

    func checkpoint(account: String, mailbox: String) -> MailboxCheckpoint? {
        let key = Data((account + "\u{0000}" + mailbox).utf8).base64EncodedString()
        return state.checkpoints[key]
    }

    private func persist() throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw MonitorStateStoreError.unableToPersist
        }
    }
}
