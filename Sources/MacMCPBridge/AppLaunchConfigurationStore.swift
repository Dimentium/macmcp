import Foundation

enum AppLaunchConfigurationError: LocalizedError, Equatable {
    case tooManyArguments
    case invalidArgument
    case passwordCommandNotAllowed
    case invalidChatGPTTunnelConfiguration
    case unableToWriteConfiguration

    var errorDescription: String? {
        switch self {
        case .tooManyArguments:
            return "Launch configuration contains too many arguments"
        case .invalidArgument:
            return "Launch configuration contains an invalid argument"
        case .passwordCommandNotAllowed:
            return "Launch configuration must not contain password commands"
        case .invalidChatGPTTunnelConfiguration:
            return "Launch configuration contains an invalid ChatGPT tunnel"
        case .unableToWriteConfiguration:
            return "Unable to save MacMCP launch configuration"
        }
    }
}

struct ChatGPTTunnelConfiguration: Equatable, Sendable {
    let tunnelID: String
    let clientPath: String
    let profile: String
}

struct AppLaunchConfigurationStore: Sendable {
    struct Configuration: Equatable, Sendable {
        let args: [String]
        let launchAtLogin: Bool
        let chatGPTTunnel: ChatGPTTunnelConfiguration?
    }

    private struct Payload: Codable {
        struct ChatGPTTunnel: Codable {
            let tunnelID: String
            let clientPath: String
            let profile: String
        }

        let schemaVersion: Int
        let args: [String]
        let launchAtLogin: Bool?
        let chatGPTTunnel: ChatGPTTunnel?
    }

    let fileURL: URL
    private let legacyFileURL: URL?

    private static let legacyStateFileNames = [
        "mail-action-access.json",
        "tunnel-failures.json"
    ]

    init() {
        self.fileURL = Self.defaultFileURL()
        self.legacyFileURL = Self.legacyFileURL()
    }

    init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("launch.json")
    }

    static func legacyFileURL() -> URL {
        MacMCPPaths.legacyApplicationSupportFile("launch.json")
    }

    func readArguments() throws -> [String]? {
        try readConfiguration()?.args
    }

    func readConfiguration() throws -> Configuration? {
        guard let configurationURL = try existingConfigurationURL() else {
            return nil
        }
        let data = try Data(contentsOf: configurationURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try validate(payload.args)
        let tunnel = try payload.chatGPTTunnel.map(validate)
        return Configuration(
            args: payload.args,
            launchAtLogin: payload.launchAtLogin ?? false,
            chatGPTTunnel: tunnel
        )
    }

    func write(
        arguments: [String],
        launchAtLogin: Bool,
        chatGPTTunnel: ChatGPTTunnelConfiguration? = nil
    ) throws {
        try validate(arguments)
        let tunnel = try chatGPTTunnel.map { configuration in
            try validate(Payload.ChatGPTTunnel(
                tunnelID: configuration.tunnelID,
                clientPath: configuration.clientPath,
                profile: configuration.profile
            ))
        }
        let payload = Payload(
            schemaVersion: 1,
            args: arguments,
            launchAtLogin: launchAtLogin,
            chatGPTTunnel: tunnel.map {
                Payload.ChatGPTTunnel(
                    tunnelID: $0.tunnelID,
                    clientPath: $0.clientPath,
                    profile: $0.profile
                )
            }
        )

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
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw AppLaunchConfigurationError.unableToWriteConfiguration
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard let configuration = try readConfiguration() else {
            throw AppLaunchConfigurationError.unableToWriteConfiguration
        }
        try write(
            arguments: configuration.args,
            launchAtLogin: enabled,
            chatGPTTunnel: configuration.chatGPTTunnel
        )
    }

    private func existingConfigurationURL() throws -> URL? {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        guard let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else {
            return nil
        }
        try migrateLegacyConfiguration(from: legacyFileURL)
        return fileURL
    }

    private func migrateLegacyConfiguration(from legacyFileURL: URL) throws {
        let data = try Data(contentsOf: legacyFileURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let arguments = Self.removingLegacySidecarPaths(from: payload.args)
        let tunnel = try payload.chatGPTTunnel.map(validate)
        try write(
            arguments: arguments,
            launchAtLogin: payload.launchAtLogin ?? false,
            chatGPTTunnel: tunnel
        )
        try copyLegacyState(from: legacyFileURL.deletingLastPathComponent())
    }

    private func copyLegacyState(from legacyDirectory: URL) throws {
        let fileManager = FileManager.default
        let targetDirectory = fileURL.deletingLastPathComponent()
        for name in Self.legacyStateFileNames {
            let source = legacyDirectory.appendingPathComponent(name)
            let target = targetDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: target.path)
            else {
                continue
            }
            try fileManager.copyItem(at: source, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    private static func removingLegacySidecarPaths(from arguments: [String]) -> [String] {
        var normalized: [String] = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard ["--mail-sidecar", "--eventkit-sidecar"].contains(option),
                  index + 1 < arguments.count,
                  isLegacySidecarPath(arguments[index + 1])
            else {
                normalized.append(option)
                index += 1
                continue
            }
            index += 2
        }
        return normalized
    }

    private static func isLegacySidecarPath(_ path: String) -> Bool {
        path.contains("/.local/opt/mac-agent-bridge/") ||
        path.contains("/Mac Agent Bridge.app/")
    }

    private func validate(_ args: [String]) throws {
        guard args.count <= 64 else {
            throw AppLaunchConfigurationError.tooManyArguments
        }
        let forbidden = Set([
            "--store-mail-password",
            "--store-icloud-password",
            "--delete-mail-password",
            "--delete-icloud-password",
            "--register-login-item",
            "--unregister-login-item",
            "--stdio-proxy"
        ])
        for argument in args {
            if forbidden.contains(argument) {
                throw AppLaunchConfigurationError.passwordCommandNotAllowed
            }
            guard argument.utf8.count <= 4096,
                  !argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw AppLaunchConfigurationError.invalidArgument
            }
        }
    }

    private func validate(_ tunnel: Payload.ChatGPTTunnel) throws -> ChatGPTTunnelConfiguration {
        guard tunnel.tunnelID.range(
            of: "^tunnel_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil,
        tunnel.clientPath.hasPrefix("/"),
        URL(fileURLWithPath: tunnel.clientPath).lastPathComponent == "tunnel-client",
        isSafeValue(tunnel.clientPath),
        tunnel.profile.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
        else {
            throw AppLaunchConfigurationError.invalidChatGPTTunnelConfiguration
        }
        return ChatGPTTunnelConfiguration(
            tunnelID: tunnel.tunnelID,
            clientPath: tunnel.clientPath,
            profile: tunnel.profile
        )
    }

    private func isSafeValue(_ value: String) -> Bool {
        value.utf8.count <= 4096 && !value.unicodeScalars.contains(
            where: CharacterSet.controlCharacters.contains
        )
    }
}
