import Foundation

enum AppConfigurationSetupError: LocalizedError, Equatable {
    case missingMailAccount
    case tunnelIDRequiresClient
    case tunnelClientRequiresID

    var errorDescription: String? {
        switch self {
        case .missingMailAccount:
            return "At least one mail account is required for setup"
        case .tunnelIDRequiresClient:
            return "ChatGPT tunnel setup requires tunnel-client"
        case .tunnelClientRequiresID:
            return "tunnel-client is only valid with a ChatGPT tunnel ID"
        }
    }
}

struct AppConfigurationSetup {
    struct Request: Equatable {
        let launchArguments: [String]
        let mailAccounts: [String]
        let launchAtLogin: Bool
        let chatGPTTunnel: ChatGPTTunnelConfiguration?
    }

    private struct PendingSecret {
        let account: String
        var value: Data
    }

    static func parse(arguments: [String]) throws -> Request {
        var launchArguments: [String] = []
        var tunnelID: String?
        var tunnelClientPath: String?
        var launchAtLogin = true
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--allow-unsafe-plain-imap":
                launchArguments.append(option)
                index += 1
            case "--icloud-address", "--gmail-address", "--mail-account":
                guard index + 1 < arguments.count else {
                    throw CommandLineInterfaceError.missingValue(option)
                }
                launchArguments.append(option)
                launchArguments.append(arguments[index + 1])
                index += 2
            case "--chatgpt-tunnel-id":
                guard index + 1 < arguments.count else {
                    throw CommandLineInterfaceError.missingValue(option)
                }
                tunnelID = arguments[index + 1]
                index += 2
            case "--chatgpt-tunnel-client":
                guard index + 1 < arguments.count else {
                    throw CommandLineInterfaceError.missingValue(option)
                }
                tunnelClientPath = arguments[index + 1]
                index += 2
            case "--no-login-item":
                launchAtLogin = false
                index += 1
            default:
                throw CommandLineInterfaceError.unknownOption(option)
            }
        }

        let configuration = try CommandLineInterface.launchConfiguration(
            arguments: launchArguments
        )
        guard !configuration.mailAccounts.isEmpty else {
            throw AppConfigurationSetupError.missingMailAccount
        }
        guard tunnelID != nil || tunnelClientPath == nil else {
            throw AppConfigurationSetupError.tunnelClientRequiresID
        }
        guard tunnelID == nil || tunnelClientPath != nil else {
            throw AppConfigurationSetupError.tunnelIDRequiresClient
        }

        let tunnel: ChatGPTTunnelConfiguration?
        if let tunnelID, let tunnelClientPath {
            tunnel = ChatGPTTunnelConfiguration(
                tunnelID: tunnelID,
                clientPath: tunnelClientPath,
                profile: "macmcp-local"
            )
        } else {
            tunnel = nil
        }
        var seenAccounts = Set<String>()
        let mailAccounts = configuration.mailAccounts.compactMap { account in
            seenAccounts.insert(account.username).inserted ? account.username : nil
        }
        return Request(
            launchArguments: launchArguments,
            mailAccounts: mailAccounts,
            launchAtLogin: launchAtLogin,
            chatGPTTunnel: tunnel
        )
    }

    static func configure(
        arguments: [String],
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        mailCredentialStore: any CredentialStore = MigratingCredentialStore.mail(),
        tunnelCredentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel(),
        loginItemController: any LoginItemControlling = SMAppLoginItemController(),
        readMailPassword: () throws -> Data = CommandLineInterface.readNewPassword,
        readTunnelKey: () throws -> Data = CommandLineInterface.readNewChatGPTTunnelKey
    ) throws {
        let request = try parse(arguments: arguments)
        var mailSecrets: [PendingSecret] = []
        var tunnelSecret: Data?
        defer {
            for index in mailSecrets.indices {
                mailSecrets[index].value.resetBytes(in: 0..<mailSecrets[index].value.count)
            }
            if var secret = tunnelSecret {
                secret.resetBytes(in: 0..<secret.count)
                tunnelSecret = secret
            }
        }

        for account in request.mailAccounts {
            mailSecrets.append(PendingSecret(account: account, value: try readMailPassword()))
        }
        if request.chatGPTTunnel != nil {
            tunnelSecret = try readTunnelKey()
        }

        for secret in mailSecrets {
            try mailCredentialStore.storeSecret(secret.value, account: secret.account)
        }
        if let tunnelSecret {
            try tunnelCredentialStore.storeSecret(
                tunnelSecret,
                account: KeychainCredentialStore.chatGPTTunnelAccount
            )
        }
        try launchConfigurationStore.write(
            arguments: request.launchArguments,
            launchAtLogin: request.launchAtLogin,
            chatGPTTunnel: request.chatGPTTunnel
        )
        if request.launchAtLogin {
            try loginItemController.register()
        }
    }
}
