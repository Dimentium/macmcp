import Foundation
import Security

protocol CredentialStore: Sendable {
    func readSecret(account: String) throws -> Data
    func storeSecret(_ secret: Data, account: String) throws
    func deleteSecret(account: String) throws
}

enum CredentialStoreError: LocalizedError, Equatable {
    case invalidAccount
    case notFound
    case unexpectedStatus(OSStatus)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            return "Credential account is invalid"
        case .notFound:
            return "No Keychain secret is stored for this account"
        case .unexpectedStatus(let status):
            return "Keychain operation failed (OSStatus \(status))"
        case .invalidResult:
            return "Keychain returned an invalid credential"
        }
    }
}

struct KeychainCredentialStore: CredentialStore {
    static let defaultService = "com.dimentium.macmcp.mail"
    static let legacyDefaultService = "com.openai.mac-agent-bridge.icloud-imap"
    static let chatGPTTunnelService = "com.dimentium.macmcp.chatgpt-tunnel"
    static let legacyChatGPTTunnelService = "com.openai.mac-agent-bridge.chatgpt-tunnel"
    static let chatGPTTunnelAccount = "runtime-api-key"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func readSecret(account: String) throws -> Data {
        try validate(account: account)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CredentialStoreError.notFound }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data, !data.isEmpty else {
            throw CredentialStoreError.invalidResult
        }
        return data
    }

    func storeSecret(_ secret: Data, account: String) throws {
        try validate(account: account)
        guard !secret.isEmpty else { throw CredentialStoreError.invalidResult }

        let query = baseQuery(account: account)
        let update = [kSecValueData as String: secret]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(insertStatus)
        }
    }

    func deleteSecret(account: String) throws {
        try validate(account: account)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func validate(account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 254,
              !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw CredentialStoreError.invalidAccount
        }
    }
}

struct MigratingCredentialStore: CredentialStore {
    private let primary: any CredentialStore
    private let legacy: any CredentialStore

    init(primary: any CredentialStore, legacy: any CredentialStore) {
        self.primary = primary
        self.legacy = legacy
    }

    static func mail() -> MigratingCredentialStore {
        MigratingCredentialStore(
            primary: KeychainCredentialStore(service: KeychainCredentialStore.defaultService),
            legacy: KeychainCredentialStore(service: KeychainCredentialStore.legacyDefaultService)
        )
    }

    static func chatGPTTunnel() -> MigratingCredentialStore {
        MigratingCredentialStore(
            primary: KeychainCredentialStore(service: KeychainCredentialStore.chatGPTTunnelService),
            legacy: KeychainCredentialStore(service: KeychainCredentialStore.legacyChatGPTTunnelService)
        )
    }

    func readSecret(account: String) throws -> Data {
        do {
            return try primary.readSecret(account: account)
        } catch CredentialStoreError.notFound {
            let secret = try legacy.readSecret(account: account)
            try primary.storeSecret(secret, account: account)
            return secret
        }
    }

    func storeSecret(_ secret: Data, account: String) throws {
        try primary.storeSecret(secret, account: account)
    }

    func deleteSecret(account: String) throws {
        try primary.deleteSecret(account: account)
        try legacy.deleteSecret(account: account)
    }
}
