import AppKit

@MainActor
final class SetupAssistant: NSObject, NSWindowDelegate {
    static let dismissalDefaultsKey = "macmcp.setupAssistantDismissed"
    static let bundledTunnelClientURL: URL? = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/tunnel-client/tunnel-client")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    enum Mode {
        case initial
        case mailOnly
        case tunnelOnly
    }

    enum Result {
        case configured
        case skipped
    }

    private let mode: Mode
    private let existingArguments: [String]
    private let completion: (Result) -> Void
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addressField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let mailCheckbox = NSButton(checkboxWithTitle: "Connect a mail account", target: nil, action: nil)
    private let tunnelCheckbox = NSButton(checkboxWithTitle: "Connect MacMCP to ChatGPT", target: nil, action: nil)
    private let tunnelIDField = NSTextField(string: "")
    private let tunnelKeyField = NSSecureTextField(string: "")
    private let loginItemCheckbox = NSButton(checkboxWithTitle: "Launch MacMCP at login", target: nil, action: nil)
    private let providerHelp = NSTextField(wrappingLabelWithString: "")
    private let tunnelHelp = NSTextField(wrappingLabelWithString: "")
    private let tunnelClientStatus = NSTextField(wrappingLabelWithString: "")
    private var tunnelClientURL: URL?
    private var window: NSWindow?
    private var mailFields: NSStackView?
    private var tunnelFields: NSStackView?
    private var isCompleting = false

    init(
        mode: Mode = .initial,
        existingArguments: [String] = [],
        bundledTunnelClientURL: URL? = nil,
        completion: @escaping (Result) -> Void
    ) {
        self.mode = mode
        self.existingArguments = existingArguments
        self.tunnelClientURL = bundledTunnelClientURL ?? Self.bundledTunnelClientURL
        self.completion = completion
        super.init()

        providerPopup.addItems(withTitles: ["Gmail", "iCloud Mail"])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false

        addressField.placeholderString = "you@example.com"
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        passwordField.placeholderString = "App-specific password"
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tunnelIDField.placeholderString = "tunnel_..."
        tunnelIDField.translatesAutoresizingMaskIntoConstraints = false
        tunnelIDField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tunnelKeyField.placeholderString = "Runtime API key"
        tunnelKeyField.translatesAutoresizingMaskIntoConstraints = false
        tunnelKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        mailCheckbox.state = .on
        mailCheckbox.target = self
        mailCheckbox.action = #selector(mailChanged)
        mailCheckbox.translatesAutoresizingMaskIntoConstraints = false

        tunnelCheckbox.target = self
        tunnelCheckbox.action = #selector(tunnelChanged)
        tunnelCheckbox.translatesAutoresizingMaskIntoConstraints = false

        loginItemCheckbox.state = .on
        loginItemCheckbox.translatesAutoresizingMaskIntoConstraints = false

        providerHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        providerHelp.textColor = .secondaryLabelColor
        providerHelp.maximumNumberOfLines = 0
        providerHelp.translatesAutoresizingMaskIntoConstraints = false

        tunnelHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tunnelHelp.textColor = .secondaryLabelColor
        tunnelHelp.maximumNumberOfLines = 0
        tunnelHelp.translatesAutoresizingMaskIntoConstraints = false

        tunnelClientStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tunnelClientStatus.textColor = .secondaryLabelColor
        tunnelClientStatus.maximumNumberOfLines = 0
        tunnelClientStatus.translatesAutoresizingMaskIntoConstraints = false

        if case .tunnelOnly = mode {
            tunnelCheckbox.state = .on
            mailCheckbox.state = .off
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 610),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.delegate = self
        self.window = window

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString: explanationText)
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        let providerLabel = NSTextField(labelWithString: "Provider")
        let addressLabel = NSTextField(labelWithString: "Email address")
        let passwordLabel = NSTextField(labelWithString: "App password")
        let mailRows = NSStackView(views: [
            makeRow(label: providerLabel, control: providerPopup),
            makeRow(label: addressLabel, control: addressField),
            makeRow(label: passwordLabel, control: passwordField),
            providerHelp
        ])
        mailRows.orientation = .vertical
        mailRows.alignment = .width
        mailRows.spacing = 8
        mailRows.translatesAutoresizingMaskIntoConstraints = false
        mailFields = mailRows

        tunnelHelp.stringValue = "Create a tunnel and a restricted runtime API key in OpenAI. Both values are saved locally; the key is stored in the macOS Keychain."
        let tunnelIDLabel = NSTextField(labelWithString: "Tunnel ID")
        let tunnelKeyLabel = NSTextField(labelWithString: "Runtime key")
        let chooseButton = NSButton(title: "Choose...", target: self, action: #selector(chooseTunnelClient))
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        let clientControl = NSStackView(views: [tunnelClientStatus, chooseButton])
        clientControl.orientation = .horizontal
        clientControl.alignment = .centerY
        clientControl.spacing = 10
        clientControl.translatesAutoresizingMaskIntoConstraints = false
        let tunnelRows = NSStackView(views: [
            tunnelHelp,
            makeRow(label: tunnelIDLabel, control: tunnelIDField),
            makeRow(label: tunnelKeyLabel, control: tunnelKeyField),
            makeRow(label: NSTextField(labelWithString: "Client"), control: clientControl),
            makeTunnelLinks()
        ])
        tunnelRows.orientation = .vertical
        tunnelRows.alignment = .width
        tunnelRows.spacing = 8
        tunnelRows.translatesAutoresizingMaskIntoConstraints = false
        tunnelFields = tunnelRows

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.addArrangedSubview(NSButton(title: "Set Up Later", target: self, action: #selector(skip)))
        buttons.addArrangedSubview(NSButton(title: "Save Settings", target: self, action: #selector(configure)))
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [
            titleLabel,
            explanation,
            mailCheckbox,
            mailRows,
            tunnelCheckbox,
            tunnelRows,
            loginItemCheckbox,
            buttons
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        if case .tunnelOnly = mode {
            mailCheckbox.isHidden = true
            mailRows.isHidden = true
            loginItemCheckbox.isHidden = true
        } else if case .mailOnly = mode {
            tunnelCheckbox.isHidden = true
            tunnelRows.isHidden = true
        }

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            explanation.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            providerHelp.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            tunnelHelp.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            tunnelClientStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            tunnelClientStatus.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            buttons.heightAnchor.constraint(equalToConstant: 32)
        ])

        updateProviderHelp()
        updateFieldAvailability()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if case .tunnelOnly = mode {
            tunnelIDField.becomeFirstResponder()
        } else {
            addressField.becomeFirstResponder()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isCompleting else { return }
        isCompleting = true
        markDismissedIfInitial()
        completion(.skipped)
    }

    private var title: String {
        switch mode {
        case .initial:
            return "Set Up MacMCP (Optional)"
        case .mailOnly:
            return "Set Up Mail"
        case .tunnelOnly:
            return "Set Up ChatGPT Tunnel"
        }
    }

    private var explanationText: String {
        switch mode {
        case .initial:
            return "Choose what MacMCP should connect to. Mail and the ChatGPT tunnel are optional; you can leave both off and use Calendar and Reminders only."
        case .mailOnly:
            return "Connect a mail account. Your app-specific password is saved in the macOS Keychain and is never put into an MCP client configuration."
        case .tunnelOnly:
            return "Connect the local MacMCP server to ChatGPT. Mail configuration, if any, is left unchanged."
        }
    }

    private func makeRow(label: NSTextField, control: NSView) -> NSView {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeTunnelLinks() -> NSView {
        let settings = NSButton(title: "Open Tunnel Settings", target: self, action: #selector(openTunnelSettings))
        let keys = NSButton(title: "Open Runtime API Keys", target: self, action: #selector(openTunnelAPIKeys))
        for button in [settings, keys] {
            button.isBordered = false
            button.alignment = .left
        }
        let links = NSStackView(views: [settings, keys])
        links.orientation = .horizontal
        links.spacing = 16
        links.translatesAutoresizingMaskIntoConstraints = false
        return links
    }

    @objc private func providerChanged() {
        updateProviderHelp()
    }

    @objc private func mailChanged() {
        updateFieldAvailability()
    }

    @objc private func tunnelChanged() {
        updateFieldAvailability()
    }

    private func updateProviderHelp() {
        if providerPopup.indexOfSelectedItem == 0 {
            providerHelp.stringValue = "Use a Google App Password. Your normal Google password will not work here."
        } else {
            providerHelp.stringValue = "Use an Apple app-specific password for iCloud Mail, not your Apple Account password."
        }
    }

    private func updateFieldAvailability() {
        let mailEnabled = mailCheckbox.state == .on
        addressField.isEnabled = mailEnabled
        passwordField.isEnabled = mailEnabled
        providerPopup.isEnabled = mailEnabled
        mailFields?.isHidden = !mailEnabled && isInitialMode

        let tunnelEnabled = tunnelCheckbox.state == .on
        tunnelIDField.isEnabled = tunnelEnabled
        tunnelKeyField.isEnabled = tunnelEnabled
        tunnelFields?.isHidden = !tunnelEnabled && isInitialMode
        tunnelClientStatus.stringValue = tunnelClientStatusText
    }

    private var isInitialMode: Bool {
        if case .initial = mode { return true }
        return false
    }

    private var tunnelClientStatusText: String {
        guard let tunnelClientURL else {
            return "tunnel-client is not included in this build. Download it or choose an existing executable."
        }
        if tunnelClientURL.path.contains("Contents/Resources/tunnel-client/") {
            return "Bundled tunnel-client is ready; Homebrew is not required."
        }
        return "Using (tunnelClientURL.path)"
    }

    @objc private func chooseTunnelClient() {
        let panel = NSOpenPanel()
        panel.title = "Choose tunnel-client"
        panel.message = "Choose the executable named tunnel-client."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "tunnel-client",
              FileManager.default.isExecutableFile(atPath: url.path)
        else {
            showError(message: "Choose an executable file named tunnel-client.")
            return
        }
        tunnelClientURL = url
        updateFieldAvailability()
    }

    @objc private func openTunnelSettings() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
    }

    @objc private func openTunnelAPIKeys() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/api-keys")!)
    }

    @objc private func skip() {
        guard !isCompleting else { return }
        isCompleting = true
        markDismissedIfInitial()
        window?.close()
        completion(.skipped)
    }

    @objc private func configure() {
        let mailEnabled = mode != .tunnelOnly && mailCheckbox.state == .on
        let tunnelEnabled = tunnelCheckbox.state == .on
        var arguments = mode == .tunnelOnly ? existingArguments : []

        if mailEnabled {
            let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                showError(message: "Enter the email address for this account.")
                return
            }
            let providerFlag = providerPopup.indexOfSelectedItem == 0 ? "--gmail-address" : "--icloud-address"
            arguments += [providerFlag, address]
        }

        var tunnelID: String?
        if tunnelEnabled {
            let value = tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                showError(message: "Enter the tunnel ID, for example tunnel_... .")
                return
            }
            guard let tunnelClientURL,
                  FileManager.default.isExecutableFile(atPath: tunnelClientURL.path)
            else {
                showError(message: "MacMCP needs an executable tunnel-client. Install the latest MacMCP DMG or choose tunnel-client manually.")
                return
            }
            tunnelID = value
        }

        var mailPassword = mailEnabled ? Data(passwordField.stringValue.utf8) : Data()
        var tunnelKey = tunnelEnabled ? Data(tunnelKeyField.stringValue.utf8) : Data()
        defer {
            mailPassword.resetBytes(in: 0..<mailPassword.count)
            tunnelKey.resetBytes(in: 0..<tunnelKey.count)
        }
        if mailEnabled && mailPassword.isEmpty {
            showError(message: "Enter the app-specific password for this account.")
            return
        }
        if tunnelEnabled && tunnelKey.isEmpty {
            showError(message: "Enter the restricted runtime API key.")
            return
        }

        do {
            switch mode {
            case .initial:
                if let tunnelID, let tunnelClientURL {
                    arguments += ["--chatgpt-tunnel-id", tunnelID, "--chatgpt-tunnel-client", tunnelClientURL.path]
                }
                if loginItemCheckbox.state != .on {
                    arguments.append("--no-login-item")
                }
                try AppConfigurationSetup.configure(
                    arguments: arguments,
                    readMailPassword: { mailPassword },
                    readTunnelKey: { tunnelKey }
                )
            case .mailOnly:
                try AppConfigurationSetup.configureMail(
                    arguments: arguments,
                    readMailPassword: { mailPassword }
                )
            case .tunnelOnly:
                guard let tunnelID, let tunnelClientURL else {
                    throw AppConfigurationSetupError.tunnelIDRequiresClient
                }
                try AppConfigurationSetup.configureTunnel(
                    tunnelID: tunnelID,
                    clientPath: tunnelClientURL.path,
                    readTunnelKey: { tunnelKey }
                )
            }
        } catch {
            showError(message: error.localizedDescription)
            return
        }

        isCompleting = true
        passwordField.stringValue = ""
        tunnelKeyField.stringValue = ""
        window?.close()
        completion(.configured)
    }

    private func markDismissedIfInitial() {
        if case .initial = mode {
            UserDefaults.standard.set(true, forKey: Self.dismissalDefaultsKey)
        }
    }

    private func showError(message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "MacMCP setup could not be completed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
