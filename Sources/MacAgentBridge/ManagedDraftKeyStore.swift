import Foundation
import Security

enum ManagedDraftKeyStoreError: LocalizedError, Equatable {
    case invalidStoredKey
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredKey:
            return "The stored managed draft key is invalid"
        case .randomGenerationFailed:
            return "Unable to generate a managed draft key"
        }
    }
}

struct ManagedDraftKeyStore: Sendable {
    static let service = "com.openai.macmcp.managed-drafts"
    static let account = "hmac-key-v1"
    static let keyLength = 32

    let credentials: any CredentialStore

    init(credentials: any CredentialStore = KeychainCredentialStore(service: Self.service)) {
        self.credentials = credentials
    }

    func loadOrCreate() throws -> Data {
        do {
            let key = try credentials.readSecret(account: Self.account)
            guard key.count == Self.keyLength else {
                throw ManagedDraftKeyStoreError.invalidStoredKey
            }
            return key
        } catch CredentialStoreError.notFound {
            var key = Data(repeating: 0, count: Self.keyLength)
            let status = key.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, Self.keyLength, bytes.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw ManagedDraftKeyStoreError.randomGenerationFailed(status)
            }
            try credentials.storeSecret(key, account: Self.account)
            return key
        }
    }
}
