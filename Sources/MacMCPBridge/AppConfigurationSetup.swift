import Foundation

enum AppConfigurationSetupError: LocalizedError, Equatable {
    case tunnelIDRequiresClient
    case tunnelClientRequiresID

    var errorDescription: String? {
        switch self {
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

    static func configureMail(
        arguments: [String],
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        mailCredentialStore: any CredentialStore = MigratingCredentialStore.mail(),
        readMailPassword: () throws -> Data = CommandLineInterface.readNewPassword
    ) throws {
        let existing = try launchConfigurationStore.readConfiguration()
        let request = try parse(arguments: arguments)
        var secrets = request.mailAccounts.map {
            PendingSecret(account: $0, value: Data())
        }
        defer {
            for index in secrets.indices {
                secrets[index].value.resetBytes(in: 0..<secrets[index].value.count)
            }
        }

        for index in secrets.indices {
            secrets[index].value = try readMailPassword()
        }
        for secret in secrets {
            try mailCredentialStore.storeSecret(secret.value, account: secret.account)
        }
        try launchConfigurationStore.write(
            arguments: request.launchArguments,
            launchAtLogin: existing?.launchAtLogin ?? true,
            chatGPTTunnel: existing?.chatGPTTunnel
        )
    }

    static func configureTunnel(
        tunnelID: String,
        clientPath: String,
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        tunnelCredentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel(),
        readTunnelKey: () throws -> Data = CommandLineInterface.readNewChatGPTTunnelKey
    ) throws {
        var key = try readTunnelKey()
        defer { key.resetBytes(in: 0..<key.count) }
        try configureTunnel(
            tunnelID: tunnelID,
            clientPath: clientPath,
            runtimeKey: key,
            launchConfigurationStore: launchConfigurationStore,
            tunnelCredentialStore: tunnelCredentialStore
        )
    }

    static func configureTunnel(
        tunnelID: String,
        clientPath: String,
        runtimeKey: Data,
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        tunnelCredentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel()
    ) throws {
        let existing = try launchConfigurationStore.readConfiguration()
        let request = try parse(arguments: [
            "--chatgpt-tunnel-id", tunnelID,
            "--chatgpt-tunnel-client", clientPath
        ] + (existing?.args ?? []))
        guard let tunnel = request.chatGPTTunnel else {
            throw AppConfigurationSetupError.tunnelIDRequiresClient
        }

        try tunnelCredentialStore.storeSecret(
            runtimeKey,
            account: KeychainCredentialStore.chatGPTTunnelAccount
        )
        try launchConfigurationStore.write(
            arguments: existing?.args ?? [],
            launchAtLogin: existing?.launchAtLogin ?? true,
            chatGPTTunnel: tunnel
        )
    }

    static func disableTunnel(
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        tunnelCredentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel()
    ) throws {
        let existing = try launchConfigurationStore.readConfiguration()
        try launchConfigurationStore.write(
            arguments: existing?.args ?? [],
            launchAtLogin: existing?.launchAtLogin ?? true,
            chatGPTTunnel: nil
        )
        try tunnelCredentialStore.deleteSecret(account: KeychainCredentialStore.chatGPTTunnelAccount)
    }
}
