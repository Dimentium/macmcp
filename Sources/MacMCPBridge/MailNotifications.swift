import Foundation
import UserNotifications

struct MailMonitorSettings: Codable, Equatable, Sendable {
    let enabled: Bool
}

enum MailMonitorSettingsError: LocalizedError, Equatable {
    case corrupt
    case unableToPersist

    var errorDescription: String? {
        switch self {
        case .corrupt:
            return "Mail notification settings are corrupt"
        case .unableToPersist:
            return "Unable to persist mail notification settings"
        }
    }
}

struct MailMonitorSettingsStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("mail-monitor.json")
    }

    func read() throws -> MailMonitorSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MailMonitorSettings(enabled: false)
        }
        do {
            return try JSONDecoder().decode(MailMonitorSettings.self, from: Data(contentsOf: fileURL))
        } catch {
            throw MailMonitorSettingsError.corrupt
        }
    }

    func save(_ settings: MailMonitorSettings) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw MailMonitorSettingsError.unableToPersist
        }
    }
}

enum MailNotificationAuthorization: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
}

enum MailNotificationPosterError: LocalizedError, Equatable {
    case notAuthorized
    case deliveryFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "macOS notifications are not authorized"
        case .deliveryFailed:
            return "Unable to deliver macOS notification"
        }
    }
}

final class MacOSAttentionNotificationPoster: @unchecked Sendable, AttentionNotificationPosting {
    private let lock = NSLock()
    private var center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        self.center = center
    }

    func authorize(allowPrompt: Bool) async -> MailNotificationAuthorization {
        let current = await authorization()
        guard current == .notDetermined, allowPrompt else { return current }
        let center = notificationCenter()
        let granted = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : await authorization()
    }

    func post(_ notification: AttentionNotification) async throws {
        guard await authorize(allowPrompt: false) == .granted else {
            throw MailNotificationPosterError.notAuthorized
        }
        let copy = Self.copy(for: notification.decision)
        let center = notificationCenter()
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { continuation in
            center.add(request) { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MailNotificationPosterError.deliveryFailed)
                }
            }
        }
    }

    static func copy(for decision: AttentionDecision) -> (title: String, body: String) {
        let body = decision.urgency == .immediate
            ? "A new message needs immediate attention."
            : "A new message needs attention."
        return (title: "MacMCP Mail", body: body)
    }

    private func authorization() async -> MailNotificationAuthorization {
        let center = notificationCenter()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func notificationCenter() -> UNUserNotificationCenter {
        lock.lock()
        defer { lock.unlock() }
        if let center { return center }
        let created = UNUserNotificationCenter.current()
        center = created
        return created
    }
}

struct MailMonitorScanSummary: Equatable, Sendable {
    let attemptedAccounts: Int
    let completedAccounts: Int
    let notified: Int
}

actor MailMonitor {
    private let scanner: MailScanner
    private let accountIDs: [String]
    private let folder: String
    private let pollIntervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(
        scanner: MailScanner,
        accountIDs: [String],
        folder: String = "INBOX",
        pollIntervalNanoseconds: UInt64 = 60_000_000_000
    ) {
        self.scanner = scanner
        self.accountIDs = Array(Set(accountIDs)).sorted()
        self.folder = folder
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start() {
        guard task == nil, !accountIDs.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func scanNow() async -> MailMonitorScanSummary {
        var completed = 0
        var notified = 0
        for accountID in accountIDs {
            guard !Task.isCancelled else { break }
            guard let result = try? await scanner.scan(accountID: accountID, folder: folder) else {
                continue
            }
            completed += 1
            notified += result.notified
        }
        return MailMonitorScanSummary(
            attemptedAccounts: accountIDs.count,
            completedAccounts: completed,
            notified: notified
        )
    }

    private func run() async {
        _ = await scanNow()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
            _ = await scanNow()
        }
    }
}
