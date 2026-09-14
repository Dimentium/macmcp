import Foundation

struct MailAccountSettingsSaveResult: Equatable, Sendable {
    let accountID: String
    let requiresRestart: Bool
}

struct MailAccountSettingsUpdater: Sendable {
    let configurationStore: MailAccountConfigurationStore
    let actionAccessStore: MailActionAccessStore
    let accountAccessStore: MailAccountAccessStore

    func save(
        accountID: String?,
        existingAccount: MailAccountConfiguration?,
        form: SettingsMailAccountForm
    ) async throws -> MailAccountSettingsSaveResult {
        let configurationChanged: Bool
        let resolvedAccountID: String

        if let accountID,
           let existingAccount,
           existingAccount.id == accountID,
           !form.changesConfiguration(from: existingAccount) {
            resolvedAccountID = accountID
            configurationChanged = false
        } else {
            let password = form.password.isEmpty ? nil : Data(form.password.utf8)
            let savedAccount = try configurationStore.save(
                accountID: accountID,
                provider: form.provider,
                username: form.username,
                imapHost: form.imapHost,
                imapPort: form.imapPort,
                imapSecurity: form.imapSecurity,
                password: password
            )
            resolvedAccountID = savedAccount.id
            configurationChanged = true
        }

        try await actionAccessStore.setReadOnly(
            !form.draftsCreationAllowed,
            for: resolvedAccountID
        )
        if accountID == nil {
            try await accountAccessStore.setEnabled(true, for: resolvedAccountID)
        }

        return MailAccountSettingsSaveResult(
            accountID: resolvedAccountID,
            requiresRestart: configurationChanged
        )
    }
}

extension SettingsMailAccountForm {
    func changesConfiguration(from account: MailAccountConfiguration) -> Bool {
        !password.isEmpty ||
            username.trimmingCharacters(in: .whitespacesAndNewlines) != account.username ||
            imapHost.trimmingCharacters(in: .whitespacesAndNewlines) != account.imapHost ||
            imapPort != account.imapPort ||
            imapSecurity != account.imapSecurity
    }
}
