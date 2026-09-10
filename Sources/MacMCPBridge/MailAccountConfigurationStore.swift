import Foundation

enum MailAccountAddressValidator {
    static func message(for username: String, provider: MailAccountProvider) -> String? {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if provider != .otherIMAP {
            guard isValidRFC5322Address(normalized) else {
                return "Enter a valid email address."
            }
            let domain = normalized.split(separator: "@", maxSplits: 1).last
                .map { String($0).lowercased() }
            switch provider {
            case .gmail where domain != "gmail.com" && domain != "googlemail.com":
                return "Gmail accounts must use a gmail.com address."
            case .iCloud where !["icloud.com", "me.com", "mac.com"].contains(domain):
                return "iCloud accounts must use an iCloud address."
            default:
                break
            }
        }
        return nil
    }

    private static func isValidRFC5322Address(_ address: String) -> Bool {
        guard address.utf8.count <= 254 else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let localPart = String(parts[0])
        let domain = String(parts[1])
        guard localPart.utf8.count <= 64, !domain.isEmpty else { return false }

        let atom = #"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let label = #"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"#
        let pattern = "^\(atom)(\\.\(atom))*@\(label)(\\.\(label))+$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(address.startIndex..<address.endIndex, in: address)
        return expression.firstMatch(in: address, range: range) != nil
    }
}

enum MailAccountConfigurationStoreError: LocalizedError, Equatable {
    case accountNotFound
    case accountAlreadyExists
    case passwordRequired
    case noLaunchConfiguration

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Mail account is no longer configured"
        case .accountAlreadyExists:
            return "That mail account is already configured"
        case .passwordRequired:
            return "Enter the account password"
        case .noLaunchConfiguration:
            return "Unable to read MacMCP launch configuration"
        }
    }
}

struct MailAccountConfigurationStore: Sendable {
    let launchConfigurationStore: AppLaunchConfigurationStore
    let credentialStore: any CredentialStore

    init(
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        credentialStore: any CredentialStore = MigratingCredentialStore.mail()
    ) {
        self.launchConfigurationStore = launchConfigurationStore
        self.credentialStore = credentialStore
    }

    func save(
        accountID: String?,
        provider: MailAccountProvider,
        username: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: MailConnectionSecurity,
        password: Data?
    ) throws -> MailAccountConfiguration {
        let existingLaunch = try launchConfigurationStore.readConfiguration()
        let existingAccounts = try configuredAccounts(from: existingLaunch?.args ?? [])
        let id: String
        if let accountID {
            guard existingAccounts.contains(where: { $0.id == accountID }) else {
                throw MailAccountConfigurationStoreError.accountNotFound
            }
            id = accountID
        } else {
            id = nextAvailableID(
                base: provider.idPrefix,
                existing: existingAccounts.map(\.id)
            )
        }

        let allowsUnsafePlaintext = imapSecurity == .plain ||
            (existingLaunch?.args.contains("--allow-unsafe-plain-imap") == true)
        let account = try makeConfiguration(
            id: id,
            provider: provider,
            username: username,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            allowsUnsafePlaintext: allowsUnsafePlaintext
        )

        if accountID == nil,
           existingAccounts.contains(where: { $0.username == account.username }) {
            throw MailAccountConfigurationStoreError.accountAlreadyExists
        }

        var storedPassword = password ?? Data()
        defer { storedPassword.resetBytes(in: 0..<storedPassword.count) }
        if storedPassword.isEmpty {
            guard var existingPassword = try? credentialStore.readSecret(account: account.username),
                  !existingPassword.isEmpty
            else {
                throw MailAccountConfigurationStoreError.passwordRequired
            }
            existingPassword.resetBytes(in: 0..<existingPassword.count)
        } else {
            try credentialStore.storeSecret(storedPassword, account: account.username)
        }

        var updatedAccounts = existingAccounts
        if let accountID, let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) {
            updatedAccounts[index] = account
        } else {
            updatedAccounts.append(account)
        }
        try write(
            accounts: updatedAccounts,
            existingArguments: existingLaunch?.args ?? [],
            launchAtLogin: existingLaunch?.launchAtLogin ?? true,
            chatGPTTunnel: existingLaunch?.chatGPTTunnel
        )

        if let accountID,
           let oldAccount = existingAccounts.first(where: { $0.id == accountID }),
           oldAccount.username != account.username {
            try? credentialStore.deleteSecret(account: oldAccount.username)
        }
        return account
    }

    func remove(accountID: String) throws {
        let existingLaunch = try launchConfigurationStore.readConfiguration()
        let existingAccounts = try configuredAccounts(from: existingLaunch?.args ?? [])
        guard let account = existingAccounts.first(where: { $0.id == accountID }) else {
            throw MailAccountConfigurationStoreError.accountNotFound
        }
        try write(
            accounts: existingAccounts.filter { $0.id != accountID },
            existingArguments: existingLaunch?.args ?? [],
            launchAtLogin: existingLaunch?.launchAtLogin ?? true,
            chatGPTTunnel: existingLaunch?.chatGPTTunnel
        )
        try? credentialStore.deleteSecret(account: account.username)
    }

    private func configuredAccounts(from arguments: [String]) throws -> [MailAccountConfiguration] {
        try CommandLineInterface.launchConfiguration(
            arguments: arguments,
            bundleURL: URL(fileURLWithPath: "/Applications/MacMCP.app"),
            resourceURL: { _ in nil }
        ).mailAccounts
    }

    private func makeConfiguration(
        id: String,
        provider: MailAccountProvider,
        username: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: MailConnectionSecurity,
        allowsUnsafePlaintext: Bool
    ) throws -> MailAccountConfiguration {
        switch provider {
        case .iCloud:
            return try MailAccountConfiguration(
                id: id,
                username: username,
                imapHost: "imap.mail.me.com",
                imapPort: 993,
                imapSecurity: .tls
            )
        case .gmail:
            return try MailAccountConfiguration(
                id: id,
                username: username,
                imapHost: "imap.gmail.com",
                imapPort: 993,
                imapSecurity: .tls
            )
        case .otherIMAP:
            return try MailAccountConfiguration(
                id: id,
                username: username,
                imapHost: imapHost,
                imapPort: imapPort,
                imapSecurity: imapSecurity,
                allowsUnsafePlaintext: allowsUnsafePlaintext
            )
        }
    }

    private func write(
        accounts: [MailAccountConfiguration],
        existingArguments: [String],
        launchAtLogin: Bool,
        chatGPTTunnel: ChatGPTTunnelConfiguration?
    ) throws {
        var arguments = removingMailArguments(from: existingArguments)
        if accounts.contains(where: { $0.imapSecurity == .plain }) {
            if !arguments.contains("--allow-unsafe-plain-imap") {
                arguments.append("--allow-unsafe-plain-imap")
            }
        } else {
            arguments.removeAll { $0 == "--allow-unsafe-plain-imap" }
        }
        for account in accounts {
            arguments.append(contentsOf: accountArguments(for: account))
        }
        try launchConfigurationStore.write(
            arguments: arguments,
            launchAtLogin: launchAtLogin,
            chatGPTTunnel: chatGPTTunnel
        )
    }

    private func removingMailArguments(from arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        let mailOptions: Set<String> = ["--icloud-address", "--gmail-address", "--mail-account"]
        while index < arguments.count {
            if mailOptions.contains(arguments[index]), index + 1 < arguments.count {
                index += 2
            } else {
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    private func accountArguments(for account: MailAccountConfiguration) -> [String] {
        if account.imapHost == "imap.mail.me.com", account.imapPort == 993,
           account.imapSecurity == .tls, account.id.hasPrefix("icloud") {
            return ["--icloud-address", account.username]
        }
        if account.imapHost == "imap.gmail.com", account.imapPort == 993,
           account.imapSecurity == .tls, account.id.hasPrefix("gmail") {
            return ["--gmail-address", account.username]
        }
        return [
            "--mail-account",
            "\(account.id)=\(account.username),\(account.imapHost),\(account.imapPort),\(account.imapSecurity.rawValue)"
        ]
    }

    private func nextAvailableID(base: String, existing: [String]) -> String {
        let existing = Set(existing)
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)\(index)") {
            index += 1
        }
        return "\(base)\(index)"
    }
}
