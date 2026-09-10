import AppKit
import SwiftUI

enum SettingsComponentStatus: Equatable {
    case ready
    case checking
    case attention
    case neutral

    var tint: Color {
        switch self {
        case .ready: return .green
        case .checking: return .orange
        case .attention: return .red
        case .neutral: return .secondary
        }
    }
}

enum SettingsUpdateState: Equatable {
    case checking
    case current
    case available(version: String)
    case installing
    case unavailable
    case sourceInstall
}

@MainActor
final class SettingsWindowModel: ObservableObject {
    struct MailAccount: Identifiable, Equatable {
        let id: String
        var provider: String
        var address: String
        var imapHost: String
        var imapPort: Int
        var imapSecurity: MailConnectionSecurity
        var enabled: Bool
        var readOnly: Bool
        var hasPassword: Bool

        var displayName: String {
            guard provider == "Other IMAP",
                  !address.contains("@"),
                  !imapHost.isEmpty else {
                return address
            }
            return "\(address) · \(imapHost)"
        }
    }

    @Published var launchAtLogin = false
    @Published var launchAtLoginAvailable = true

    @Published var localBridgeConfigured = false
    @Published var localBridgeEnabled = false
    @Published var localBridgeStatus = "Off"
    @Published var localBridgeToggleAvailable = false

    @Published var tunnelConfigured = false
    @Published var tunnelEnabled = false
    @Published var tunnelStatus = "Off"
    @Published var tunnelToggleAvailable = false

    @Published var eventKitConfigured = false
    @Published var calendarAccess = false
    @Published var calendarReadOnly = true
    @Published var calendarSettingsAvailable = false
    @Published var remindersAccess = false
    @Published var remindersReadOnly = true
    @Published var remindersSettingsAvailable = false

    @Published var mailAccounts: [MailAccount] = [] {
        didSet { onMailAccountCountChanged?(mailAccounts.count) }
    }
    @Published var mailAccountToggleAvailable = false
    @Published var showingAddMailAccount = false
    @Published var showingMailAccountSettings = false
    @Published var selectedMailAccountID: String?
    @Published var updateState: SettingsUpdateState = .checking
    @Published var version = AppVersion.version

    var onMailAccountCountChanged: ((Int) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onLocalBridgeChanged: ((Bool) -> Void)?
    var onTunnelChanged: ((Bool) -> Void)?
    var onTunnelRestart: (() -> Void)?
    var onOpenTunnelSettings: (() -> Void)?
    var onCalendarChanged: ((Bool) -> Void)?
    var onRemindersChanged: ((Bool) -> Void)?
    var onOpenCalendarSettings: (() -> Void)?
    var onOpenRemindersSettings: (() -> Void)?
    var onMailAccountChanged: ((String, Bool) -> Void)?
    var onOpenMailAccountSettings: ((String) -> Void)?
    var onAddMailAccount: (() -> Void)?
    var onSaveMailAccount: ((String?, SettingsMailAccountForm) -> Void)?
    var onRemoveMailAccount: ((String) -> Void)?
    var onOpenLogs: (() -> Void)?
    var onUpdate: (() -> Void)?

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        onLaunchAtLoginChanged?(enabled)
    }

    func setLocalBridgeEnabled(_ enabled: Bool) {
        localBridgeEnabled = enabled
        onLocalBridgeChanged?(enabled)
    }

    func setTunnelEnabled(_ enabled: Bool) {
        tunnelEnabled = enabled
        onTunnelChanged?(enabled)
    }

    func setCalendarAccess(_ enabled: Bool) {
        calendarAccess = enabled
        onCalendarChanged?(enabled)
    }

    func setRemindersAccess(_ enabled: Bool) {
        remindersAccess = enabled
        onRemindersChanged?(enabled)
    }

    func setMailAccountEnabled(id: String, enabled: Bool) {
        guard let index = mailAccounts.firstIndex(where: { $0.id == id }) else { return }
        mailAccounts[index].enabled = enabled
        onMailAccountChanged?(id, enabled)
    }
}

@MainActor
final class SettingsWindowController: NSObject {
    private static let windowWidth: CGFloat = 520
    private var window: NSWindow?
    private let model: SettingsWindowModel

    override init() {
        self.model = SettingsWindowModel()
        super.init()
        wireModel()
    }

    init(model: SettingsWindowModel) {
        self.model = model
        super.init()
        wireModel()
    }

    private func wireModel() {
        model.onMailAccountCountChanged = { [weak self] count in
            self?.resizeWindow(for: count, animated: true)
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsWindowView(model: model)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacMCP Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(
            NSSize(
                width: Self.windowWidth,
                height: Self.windowHeight(for: model.mailAccounts.count)
            )
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func windowHeight(for accountCount: Int) -> CGFloat {
        min(760, 568 + CGFloat(accountCount) * 34)
    }

    private func resizeWindow(for accountCount: Int, animated: Bool) {
        guard let window else { return }
        let contentSize = NSSize(
            width: Self.windowWidth,
            height: Self.windowHeight(for: accountCount)
        )
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = window.frame
        frame.origin.y += frame.height - frameSize.height
        frame.size = frameSize
        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: SettingsWindowModel
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    SettingsAccessControlContent(model: model)
                        .padding(32)
                        .frame(maxWidth: 500, alignment: .leading)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: SettingsContentHeightKey.self,
                                    value: content.size.height
                                )
                            }
                        }
                }
                .scrollDisabled(contentHeight <= viewport.size.height + 1)
                .onPreferenceChange(SettingsContentHeightKey.self) { height in
                    contentHeight = height
                }
            }

            Divider()
            SettingsWindowFooter(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingAddMailAccount) {
            SettingsMailAccountEditor(
                account: nil,
                onSave: { form in
                    model.onSaveMailAccount?(nil, form)
                }
            )
        }
        .sheet(isPresented: $model.showingMailAccountSettings) {
            if let accountID = model.selectedMailAccountID,
               let account = model.mailAccounts.first(where: { $0.id == accountID }) {
                SettingsMailAccountEditor(
                    account: account,
                    onSave: { form in
                        model.onSaveMailAccount?(accountID, form)
                    },
                    onRemove: {
                        model.onRemoveMailAccount?(accountID)
                    }
                )
            }
        }
    }
}

private struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsAccessControlContent: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.body.weight(.medium))
            SettingsToggleRow(
                title: "Launch at login",
                detail: "Start MacMCP automatically when you sign in.",
                icon: "power",
                enabled: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ),
                disabled: !model.launchAtLoginAvailable
            )
            Divider()
            SettingsAccessRow(
                title: "Local bridge",
                detail: "Local MCP clients on this Mac",
                secondaryDetail: model.tunnelConfigured ? "Also required by ChatGPT Tunnel" : nil,
                status: model.localBridgeStatus,
                statusTint: model.localBridgeConfigured && model.localBridgeEnabled ? .green : .secondary,
                configured: model.localBridgeConfigured,
                enabled: Binding(
                    get: { model.localBridgeEnabled },
                    set: { model.setLocalBridgeEnabled($0) }
                ),
                toggleAvailable: model.localBridgeToggleAvailable,
                onRestart: nil,
                onSettings: nil,
                restartEnabled: false
            )
            Divider()
            SettingsAccessRow(
                title: "ChatGPT Tunnel",
                detail: model.tunnelConfigured ? "Remote MCP access" : "Not configured",
                secondaryDetail: nil,
                status: model.tunnelStatus,
                statusTint: tunnelTint,
                configured: model.tunnelConfigured,
                enabled: Binding(
                    get: { model.tunnelEnabled },
                    set: { model.setTunnelEnabled($0) }
                ),
                toggleAvailable: model.tunnelToggleAvailable,
                onRestart: { model.onTunnelRestart?() },
                onSettings: { model.onOpenTunnelSettings?() },
                restartEnabled: model.tunnelConfigured && model.tunnelEnabled
            )
            Divider()
            Text("EventKit")
                .font(.body.weight(.medium))
            SettingsPermissionRow(
                title: "Calendar",
                icon: "calendar",
                detail: model.eventKitConfigured ? "EventKit connected" : "Not configured",
                configured: model.eventKitConfigured,
                readOnly: model.calendarReadOnly,
                enabled: Binding(
                    get: { model.calendarAccess },
                    set: { model.setCalendarAccess($0) }
                ),
                settingsAvailable: model.calendarSettingsAvailable,
                onSettings: { model.onOpenCalendarSettings?() }
            )
            Divider()
            SettingsPermissionRow(
                title: "Reminders",
                icon: "checklist",
                detail: model.eventKitConfigured ? "EventKit connected" : "Not configured",
                configured: model.eventKitConfigured,
                readOnly: model.remindersReadOnly,
                enabled: Binding(
                    get: { model.remindersAccess },
                    set: { model.setRemindersAccess($0) }
                ),
                settingsAvailable: model.remindersSettingsAvailable,
                onSettings: { model.onOpenRemindersSettings?() }
            )
            Divider()
            SettingsMailAccountsSection(model: model)
        }
    }

    private var tunnelTint: Color {
        guard model.tunnelConfigured, model.tunnelEnabled else { return .secondary }
        return model.tunnelStatus == "Connected" ? .green : .red
    }
}

private struct SettingsAccessRow: View {
    let title: String
    let detail: String
    let secondaryDetail: String?
    let status: String
    let statusTint: Color
    let configured: Bool
    @Binding var enabled: Bool
    let toggleAvailable: Bool
    let onRestart: (() -> Void)?
    let onSettings: (() -> Void)?
    let restartEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: title == "Local bridge" ? "point.3.connected.trianglepath.dotted" : "network")
                .font(.system(size: 18))
                .foregroundStyle(configured && enabled ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let secondaryDetail {
                    Text(secondaryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SettingsStatusPill(text: status, color: statusTint)
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!restartEnabled)
                .help("Restart tunnel")
            }
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Tunnel settings")
            }
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!configured || !toggleAvailable)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var enabled: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let icon: String
    let detail: String
    let configured: Bool
    let readOnly: Bool
    @Binding var enabled: Bool
    let settingsAvailable: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(configured ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if readOnly {
                SettingsReadOnlyChip()
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!configured || !settingsAvailable)
            .help("\(title) settings")
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!configured)
        }
    }
}

private struct SettingsMailAccountsSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mail accounts")
                .font(.body.weight(.medium))
            ForEach($model.mailAccounts) { $account in
                SettingsMailAccountRow(
                    account: $account,
                    toggleAvailable: model.mailAccountToggleAvailable,
                    onSettings: { model.onOpenMailAccountSettings?(account.id) },
                    onEnabledChanged: { model.setMailAccountEnabled(id: account.id, enabled: $0) }
                )
            }
            Button {
                model.onAddMailAccount?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add account")
                            .font(.body.weight(.medium))
                        Text("Connect another mail account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }
}

private struct SettingsMailAccountRow: View {
    @Binding var account: SettingsWindowModel.MailAccount
    let toggleAvailable: Bool
    let onSettings: () -> Void
    let onEnabledChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.provider == "iCloud Mail" ? "icloud" : "envelope")
                .font(.system(size: 18))
                .foregroundStyle(account.enabled ? Color.green : Color.secondary)
                .frame(width: 24)
            Text(account.displayName)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Spacer()
            if account.readOnly {
                SettingsReadOnlyChip()
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Account settings")
            Toggle("", isOn: Binding(
                get: { account.enabled },
                set: {
                    account.enabled = $0
                    onEnabledChanged($0)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!toggleAvailable)
        }
        .opacity(account.enabled ? 1 : 0.58)
    }
}

private struct SettingsStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct SettingsReadOnlyChip: View {
    var body: some View {
        Text("Read-only")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct SettingsMailAccountForm: Equatable {
    var provider: MailAccountProvider
    var username: String
    var password: String
    var imapHost: String
    var imapPort: Int
    var imapSecurity: MailConnectionSecurity
    var draftsCreationAllowed: Bool
}

private struct SettingsMailAccountEditor: View {
    let account: SettingsWindowModel.MailAccount?
    let onSave: (SettingsMailAccountForm) -> Void
    var onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var provider: MailAccountProvider
    @State private var username: String
    @State private var password = ""
    @State private var imapHost: String
    @State private var imapPort: String
    @State private var imapSecurity: MailConnectionSecurity
    @State private var draftsCreationAllowed: Bool

    init(
        account: SettingsWindowModel.MailAccount?,
        onSave: @escaping (SettingsMailAccountForm) -> Void,
        onRemove: (() -> Void)? = nil
    ) {
        self.account = account
        self.onSave = onSave
        self.onRemove = onRemove
        _provider = State(initialValue: account.flatMap {
            MailAccountProvider(rawValue: $0.provider)
        } ?? .gmail)
        _username = State(initialValue: account?.address ?? "")
        _imapHost = State(initialValue: account?.imapHost ?? "")
        _imapPort = State(initialValue: String(account?.imapPort ?? 993))
        _imapSecurity = State(initialValue: account?.imapSecurity ?? .tls)
        _draftsCreationAllowed = State(initialValue: account.map { !$0.readOnly } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account == nil ? "Add Mail Account" : "Mail Account")
                .font(.title2.weight(.semibold))

            if account == nil {
                Text("Connect a provider and account. The app-specific password is stored in macOS Keychain.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Provider", selection: $provider) {
                ForEach(MailAccountProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(account != nil)

            TextField(
                provider == .otherIMAP ? "Username" : "Email address",
                text: $username
            )
            .textFieldStyle(.roundedBorder)
            .disabled(account != nil)

            if provider == .otherIMAP {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        TextField("IMAP host", text: $imapHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $imapPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                    }
                    Picker("Security", selection: $imapSecurity) {
                        Text("TLS").tag(MailConnectionSecurity.tls)
                        Text("STARTTLS").tag(MailConnectionSecurity.starttls)
                        Text("Plain").tag(MailConnectionSecurity.plain)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            SecureField(
                account == nil ? "App-specific password" : "Password (leave blank to keep current)",
                text: $password
            )
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drafts creation allowed")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $draftsCreationAllowed)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Text("Always read-only. Enable this to also allow creating and updating drafts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(validationMessage ?? " ")
                .font(.caption)
                .foregroundStyle(validationMessage == nil ? Color.clear : Color.red)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                if let onRemove {
                    Button("Remove account", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(account == nil ? "Add account" : "Apply") {
                    onSave(SettingsMailAccountForm(
                        provider: provider,
                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        imapHost: imapHost.trimmingCharacters(in: .whitespacesAndNewlines),
                        imapPort: Int(imapPort) ?? 0,
                        imapSecurity: imapSecurity,
                        draftsCreationAllowed: draftsCreationAllowed
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420, height: 410, alignment: .topLeading)
    }

    private var validationMessage: String? {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else { return "Enter a username or email address." }
        if let message = MailAccountAddressValidator.message(
            for: normalizedUsername,
            provider: provider
        ) {
            return message
        }
        guard provider == .otherIMAP else { return nil }
        guard !imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an IMAP host."
        }
        guard Int(imapPort).map({ (1...65535).contains($0) }) == true else {
            return "Enter a port from 1 to 65535."
        }
        return nil
    }

    private var canSave: Bool {
        validationMessage == nil &&
            (account != nil || !password.isEmpty)
    }
}

private struct SettingsWindowFooter: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        HStack {
            Link(
                "Version \(model.version)",
                destination: URL(string: "https://github.com/Dimentium/macmcp")!
            )
            .font(.caption)
            Button {
                model.onOpenLogs?()
            } label: {
                Label("Logs", systemImage: "folder")
            }
            .help("Open logs folder")
            Spacer()
            if case .available = model.updateState {
                Text("Update available")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Update") {
                    model.onUpdate?()
                }
            }
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
