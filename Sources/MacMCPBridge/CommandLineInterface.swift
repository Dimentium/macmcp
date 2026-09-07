import Darwin
import Foundation

enum CommandLineInterfaceError: LocalizedError, Equatable {
    case missingValue(String)
    case unknownOption(String)
    case invalidMailAccount(String)
    case passwordRequiresTerminal
    case emptyPassword
    case passwordMismatch
    case secretTooLong
    case passwordReadFailed

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .invalidMailAccount(let value):
            return "Invalid mail account: \(value)"
        case .passwordRequiresTerminal:
            return "Password setup requires an interactive Terminal"
        case .emptyPassword:
            return "Password must not be empty"
        case .passwordMismatch:
            return "Passwords do not match"
        case .secretTooLong:
            return "Secret is too long"
        case .passwordReadFailed:
            return "Unable to read secret from Terminal"
        }
    }
}

enum CommandLineInterface {
    static let maximumSecretLength = 4_096

    static let help = """
    Usage:
      macmcp-bridge [--mail-sidecar PATH]
                       [--icloud-address ADDRESS] [--gmail-address ADDRESS]
                       [--mail-account ID=ADDRESS[,HOST[,PORT[,tls|starttls|plain]]]]
                       [--allow-unsafe-plain-imap]
                       [--eventkit-sidecar PATH] [--menu-bar]
      macmcp-bridge --store-mail-password ADDRESS
      macmcp-bridge --delete-mail-password ADDRESS
      macmcp-bridge --store-chatgpt-tunnel-key
      macmcp-bridge --delete-chatgpt-tunnel-key
      macmcp-bridge --stdio-proxy SOCKET_PATH
      macmcp-bridge --status-json
      macmcp-bridge --diagnose-json
      macmcp-bridge --client-approvals-json
      macmcp-bridge --approve-pending-client
      macmcp-bridge --revoke-client FINGERPRINT
      macmcp-bridge --login-item-status
      macmcp-bridge --verify-configured-mail-keychain
      macmcp-bridge --register-login-item
      macmcp-bridge --unregister-login-item
      macmcp-bridge --version

    --icloud-address and --gmail-address are provider presets. Repeat mail
    account flags to configure multiple mailboxes. Passwords are read without
    echo and stored in macOS Keychain by account address. Never put a password
    in command-line arguments or environment variables. Plain IMAP is rejected
    unless --allow-unsafe-plain-imap is explicitly present; prefer TLS or
    STARTTLS. --status-json queries
    the running MacMCP menu-bar app over local IPC. --diagnose-json prints a
    sanitized local runtime report and does not expose account identifiers,
    client names, file paths, or secrets.

    """

    static func launchConfiguration(arguments: [String]) throws -> BridgeLaunchConfiguration {
        try launchConfiguration(
            arguments: arguments,
            bundleURL: Bundle.main.bundleURL,
            resourceURL: { name in Bundle.main.url(forResource: name, withExtension: nil) }
        )
    }

    static func launchConfiguration(
        arguments: [String],
        bundleURL: URL,
        resourceURL: (String) -> URL?
    ) throws -> BridgeLaunchConfiguration {
        var mail: URL?
        var eventKit: URL?
        var mailAccounts: [MailAccountConfiguration] = []
        var menuBar = bundleURL.pathExtension == "app"
        let allowsUnsafePlaintext = arguments.contains("--allow-unsafe-plain-imap")
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            if option == "--menu-bar" {
                menuBar = true
                index += 1
                continue
            }
            if option == "--allow-unsafe-plain-imap" {
                index += 1
                continue
            }
            if option == "--enable-local-mail-actions" {
                // Kept as a no-op so an existing launch configuration from
                // before the per-account Read only control still starts.
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw CommandLineInterfaceError.missingValue(option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--mail-sidecar":
                mail = URL(fileURLWithPath: value)
            case "--eventkit-sidecar":
                eventKit = URL(fileURLWithPath: value)
            case "--icloud-address":
                mailAccounts.append(
                    try MailAccountConfiguration.iCloud(
                        address: value,
                        id: nextAvailableID(base: "icloud", existing: mailAccounts.map(\.id))
                    )
                )
            case "--gmail-address":
                mailAccounts.append(
                    try MailAccountConfiguration.gmail(
                        address: value,
                        id: nextAvailableID(base: "gmail", existing: mailAccounts.map(\.id))
                    )
                )
            case "--mail-account":
                mailAccounts.append(try parseMailAccount(
                    value,
                    allowsUnsafePlaintext: allowsUnsafePlaintext
                ))
            default:
                throw CommandLineInterfaceError.unknownOption(option)
            }
            index += 2
        }

        if menuBar, eventKit == nil {
            eventKit = resourceURL("CheICalMCP")
        }

        return BridgeLaunchConfiguration(
            mailSidecarURL: mail,
            eventKitSidecarURL: eventKit,
            mailAccounts: mailAccounts,
            menuBar: menuBar
        )
    }

    private static func parseMailAccount(
        _ value: String,
        allowsUnsafePlaintext: Bool
    ) throws -> MailAccountConfiguration {
        let idAndRest = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard idAndRest.count == 2 else {
            throw CommandLineInterfaceError.invalidMailAccount(value)
        }
        let id = idAndRest[0]
        let parts = idAndRest[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts[0].isEmpty else {
            throw CommandLineInterfaceError.invalidMailAccount(value)
        }

        do {
            if parts.count == 1 {
                return try MailAccountConfiguration.defaults(id: id, username: parts[0])
            }
            guard (2...4).contains(parts.count), !parts[1].isEmpty else {
                throw CommandLineInterfaceError.invalidMailAccount(value)
            }
            let port: Int
            if parts.count >= 3, !parts[2].isEmpty {
                guard let parsedPort = Int(parts[2]) else {
                    throw CommandLineInterfaceError.invalidMailAccount(value)
                }
                port = parsedPort
            } else {
                port = 993
            }
            let security: MailConnectionSecurity
            if parts.count >= 4, !parts[3].isEmpty {
                guard let parsedSecurity = MailConnectionSecurity(rawValue: parts[3]) else {
                    throw CommandLineInterfaceError.invalidMailAccount(value)
                }
                security = parsedSecurity
            } else {
                security = .tls
            }
            return try MailAccountConfiguration(
                id: id,
                username: parts[0],
                imapHost: parts[1],
                imapPort: port,
                imapSecurity: security,
                allowsUnsafePlaintext: allowsUnsafePlaintext
            )
        } catch let error as CommandLineInterfaceError {
            throw error
        } catch {
            throw CommandLineInterfaceError.invalidMailAccount(value)
        }
    }

    private static func nextAvailableID(base: String, existing: [String]) -> String {
        let existing = Set(existing)
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)\(index)") {
            index += 1
        }
        return "\(base)\(index)"
    }

    static func readNewPassword() throws -> Data {
        try readNewSecret(
            firstPrompt: "Mail password: ",
            confirmationPrompt: "Confirm password: "
        )
    }

    static func readNewChatGPTTunnelKey() throws -> Data {
        try readNewSecret(
            firstPrompt: "ChatGPT tunnel runtime API key: ",
            confirmationPrompt: "Confirm runtime API key: "
        )
    }

    private static func readNewSecret(
        firstPrompt: String,
        confirmationPrompt: String
    ) throws -> Data {
        guard isatty(STDIN_FILENO) == 1 else {
            throw CommandLineInterfaceError.passwordRequiresTerminal
        }
        var first = try readPassword(prompt: firstPrompt)
        defer { first.resetBytes(in: 0..<first.count) }
        var second = try readPassword(prompt: confirmationPrompt)
        defer { second.resetBytes(in: 0..<second.count) }
        guard first == second else { throw CommandLineInterfaceError.passwordMismatch }
        return first
    }

    private static func readPassword(prompt: String) throws -> Data {
        FileHandle.standardError.write(Data(prompt.utf8))

        var originalSettings = termios()
        guard tcgetattr(STDIN_FILENO, &originalSettings) == 0 else {
            throw CommandLineInterfaceError.passwordReadFailed
        }
        var hiddenSettings = originalSettings
        hiddenSettings.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hiddenSettings) == 0 else {
            throw CommandLineInterfaceError.passwordReadFailed
        }
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalSettings)
            FileHandle.standardError.write(Data("\n".utf8))
        }

        var bytes: [UInt8] = []
        defer {
            for index in bytes.indices {
                bytes[index] = 0
            }
        }

        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CommandLineInterfaceError.passwordReadFailed
            }
            if byte == 0x0A || byte == 0x0D { break }
            guard bytes.count < maximumSecretLength else {
                throw CommandLineInterfaceError.secretTooLong
            }
            bytes.append(byte)
        }

        guard !bytes.isEmpty else { throw CommandLineInterfaceError.emptyPassword }
        return Data(bytes)
    }
}
