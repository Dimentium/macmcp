import Foundation

enum MailConnectionSecurity: String, Equatable, Sendable {
    case tls
    case starttls
    case plain
}

struct MailAccountConfiguration: Equatable, Sendable {
    let id: String
    let username: String
    let imapHost: String
    let imapPort: Int
    let imapSecurity: MailConnectionSecurity

    static func iCloud(address: String, id: String = "icloud") throws -> MailAccountConfiguration {
        try MailAccountConfiguration(
            id: id,
            username: address,
            imapHost: "imap.mail.me.com",
            imapPort: 993,
            imapSecurity: .tls
        )
    }

    static func gmail(address: String, id: String = "gmail") throws -> MailAccountConfiguration {
        try MailAccountConfiguration(
            id: id,
            username: address,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            imapSecurity: .tls
        )
    }

    static func defaults(id: String, username: String) throws -> MailAccountConfiguration {
        let domain = username.split(separator: "@").last.map { String($0).lowercased() }
        switch domain {
        case "icloud.com", "me.com", "mac.com":
            return try MailAccountConfiguration(
                id: id,
                username: username,
                imapHost: "imap.mail.me.com",
                imapPort: 993,
                imapSecurity: .tls
            )
        case "gmail.com", "googlemail.com":
            return try MailAccountConfiguration(
                id: id,
                username: username,
                imapHost: "imap.gmail.com",
                imapPort: 993,
                imapSecurity: .tls
            )
        default:
            throw MailSidecarConfigurationError.unsupportedMailProvider
        }
    }

    init(
        id: String,
        username: String,
        imapHost: String,
        imapPort: Int = 993,
        imapSecurity: MailConnectionSecurity = .tls
    ) throws {
        try Self.validateID(id)
        try Self.validateUsername(username)
        try Self.validateHost(imapHost)
        guard (1...65535).contains(imapPort) else {
            throw MailSidecarConfigurationError.invalidPort
        }
        self.id = id
        self.username = username
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
    }

    private static func validateID(_ id: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !id.isEmpty, id.utf8.count <= 64,
              id.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw MailSidecarConfigurationError.invalidAccountID
        }
    }

    private static func validateUsername(_ username: String) throws {
        guard !username.isEmpty, username.utf8.count <= 254, username.contains("@"),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MailSidecarConfigurationError.invalidUsername
        }
    }

    private static func validateHost(_ host: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw MailSidecarConfigurationError.invalidHost
        }
    }
}

struct MailAccountSecret: Sendable {
    let configuration: MailAccountConfiguration
    var password: Data
}

struct MaterializedMailConfiguration: Sendable {
    let fileURL: URL
    let directoryURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

enum MailSidecarConfigurationError: LocalizedError, Equatable {
    case invalidAccountID
    case invalidUsername
    case invalidHost
    case invalidPort
    case unsupportedMailProvider
    case noAccounts
    case duplicateAccountID(String)
    case secretEncoding
    case unableToCreatePrivateFile

    var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            return "Mail account id is invalid"
        case .invalidUsername:
            return "Mail username is invalid"
        case .invalidHost:
            return "Mail IMAP host is invalid"
        case .invalidPort:
            return "Mail IMAP port is invalid"
        case .unsupportedMailProvider:
            return "Mail provider needs an explicit IMAP host"
        case .noAccounts:
            return "At least one mail account is required"
        case .duplicateAccountID(let id):
            return "Mail account id is duplicated: \(id)"
        case .secretEncoding:
            return "Unable to encode the temporary mail configuration"
        case .unableToCreatePrivateFile:
            return "Unable to create a private temporary mail configuration"
        }
    }
}

struct MailSidecarConfigurationMaterializer {
    let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    func materialize(
        address: String,
        password: Data,
        attachmentDirectory: URL? = nil
    ) throws -> MaterializedMailConfiguration {
        try materialize(accounts: [
            MailAccountSecret(
                configuration: .iCloud(address: address),
                password: password
            )
        ], attachmentDirectory: attachmentDirectory)
    }

    func materialize(
        accounts: [MailAccountSecret],
        attachmentDirectory: URL? = nil
    ) throws -> MaterializedMailConfiguration {
        guard !accounts.isEmpty else { throw MailSidecarConfigurationError.noAccounts }
        var seenIDs = Set<String>()
        for account in accounts {
            guard seenIDs.insert(account.configuration.id).inserted else {
                throw MailSidecarConfigurationError.duplicateAccountID(account.configuration.id)
            }
        }

        let directory = temporaryRoot.appendingPathComponent(
            "mac-agent-bridge-\(UUID().uuidString)",
            isDirectory: true
        )
        let file = directory.appendingPathComponent("mail-reader.yml")
        let resolvedAttachmentDirectory = attachmentDirectory ?? directory

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )

            let yaml = try """
            allow_send: false
            allow_delete: false
            limits:
              max_body_chars: 12000
              max_search_results: 25
              max_attachment_bytes: \(AttachmentStorage.maximumAttachmentBytes)
              attachment_dir: \(try yamlScalar(resolvedAttachmentDirectory.path))
            accounts:
            \(accountYAML(accounts: accounts))
            """

            try Data(yaml.utf8).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
            return MaterializedMailConfiguration(fileURL: file, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let typed = error as? MailSidecarConfigurationError { throw typed }
            throw MailSidecarConfigurationError.unableToCreatePrivateFile
        }
    }

    private func yamlScalar(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        // JSON string syntax is a safe subset of YAML double-quoted scalars,
        // except that JSON permits escaping `/` while YAML rejects `\/`.
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw MailSidecarConfigurationError.secretEncoding
        }
        return encoded
    }

    private func accountYAML(accounts: [MailAccountSecret]) throws -> String {
        try accounts.map { account in
            guard let passwordString = String(data: account.password, encoding: .utf8),
                  !passwordString.isEmpty
            else {
                throw MailSidecarConfigurationError.secretEncoding
            }
            let config = account.configuration
            return """
              - id: \(try yamlScalar(config.id))
                imap:
                  host: \(try yamlScalar(config.imapHost))
                  port: \(config.imapPort)
                  security: \(config.imapSecurity.rawValue)
                  username: \(try yamlScalar(config.username))
                  password: \(try yamlScalar(passwordString))
                smtp:
                  # mail-mcp inherits missing SMTP fields from IMAP. Supply a
                  # closed local sink so the reader config never grants SMTP
                  # authority or duplicates the mail secret.
                  host: 127.0.0.1
                  port: 1
                  security: plain
                  username: disabled@example.invalid
                  password: disabled
                allow_send: false
                allow_delete: false
                save_sent: false
            """
        }.joined(separator: "\n")
    }
}
