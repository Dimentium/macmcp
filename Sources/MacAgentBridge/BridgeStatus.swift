import Foundation

struct BridgeStatus: Codable, Equatable {
    enum Mode: String, Codable {
        case reader
    }

    enum ComponentState: String, Codable {
        case notConfigured = "not_configured"
        case connectedUnverified = "connected_unverified"
        case ready
        case unavailable
    }

    let version: String
    let mode: Mode
    let mail: ComponentState
    let calendar: ComponentState
    let reminders: ComponentState
    let writeCapabilitiesEnabled: Bool

    static let initial = BridgeStatus(
        version: AppVersion.version,
        mode: .reader,
        mail: .notConfigured,
        calendar: .notConfigured,
        reminders: .notConfigured,
        writeCapabilitiesEnabled: false
    )

    static func connected(mail: Bool, eventKit: Bool) -> BridgeStatus {
        BridgeStatus(
            version: AppVersion.version,
            mode: .reader,
            mail: mail ? .connectedUnverified : .notConfigured,
            calendar: eventKit ? .connectedUnverified : .notConfigured,
            reminders: eventKit ? .connectedUnverified : .notConfigured,
            writeCapabilitiesEnabled: false
        )
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

actor BridgeStatusSource {
    private var status: BridgeStatus

    init(status: BridgeStatus = .initial) {
        self.status = status
    }

    func snapshot() -> BridgeStatus {
        status
    }

    func updateCalendar(_ state: BridgeStatus.ComponentState) {
        status = BridgeStatus(
            version: status.version,
            mode: status.mode,
            mail: status.mail,
            calendar: state,
            reminders: status.reminders,
            writeCapabilitiesEnabled: status.writeCapabilitiesEnabled
        )
    }

    func updateMail(_ state: BridgeStatus.ComponentState) {
        status = BridgeStatus(
            version: status.version,
            mode: status.mode,
            mail: state,
            calendar: status.calendar,
            reminders: status.reminders,
            writeCapabilitiesEnabled: status.writeCapabilitiesEnabled
        )
    }

    func updateReminders(_ state: BridgeStatus.ComponentState) {
        status = BridgeStatus(
            version: status.version,
            mode: status.mode,
            mail: status.mail,
            calendar: status.calendar,
            reminders: state,
            writeCapabilitiesEnabled: status.writeCapabilitiesEnabled
        )
    }
}
