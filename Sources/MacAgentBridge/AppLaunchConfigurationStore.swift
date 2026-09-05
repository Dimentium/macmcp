import Foundation

enum AppLaunchConfigurationError: LocalizedError, Equatable {
    case tooManyArguments
    case invalidArgument
    case passwordCommandNotAllowed
    case invalidChatGPTTunnelConfiguration

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

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mac-agent-bridge", isDirectory: true)
            .appendingPathComponent("launch.json")
    }

    func readArguments() throws -> [String]? {
        try readConfiguration()?.args
    }

    func readConfiguration() throws -> Configuration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try validate(payload.args)
        let tunnel = try payload.chatGPTTunnel.map(validate)
        return Configuration(
            args: payload.args,
            launchAtLogin: payload.launchAtLogin ?? false,
            chatGPTTunnel: tunnel
        )
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
