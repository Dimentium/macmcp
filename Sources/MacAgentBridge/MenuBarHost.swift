import AppKit

@MainActor
final class MenuBarHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum MailNotificationState: Equatable {
        case off
        case starting
        case monitoring
        case needsPermission
        case unavailable
    }

    struct StatusMenuItems {
        let overall: NSMenuItem
        let mail: NSMenuItem
        let calendar: NSMenuItem
        let reminders: NSMenuItem
        let notifications: NSMenuItem
        let loginItem: NSMenuItem
        let tunnel: NSMenuItem
        let clients: NSMenuItem

        init(
            overall: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            mail: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            calendar: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            reminders: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            notifications: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            loginItem: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            tunnel: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""),
            clients: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        ) {
            self.overall = overall
            self.mail = mail
            self.calendar = calendar
            self.reminders = reminders
            self.notifications = notifications
            self.loginItem = loginItem
            self.tunnel = tunnel
            self.clients = clients
        }
    }

    private let configuration: BridgeLaunchConfiguration
    private let launchConfigurationStore: AppLaunchConfigurationStore
    private let loginItemController: (any LoginItemControlling)?
    private let clientApprovalStore: ClientApprovalStore
    private let mailMonitorSettingsStore: MailMonitorSettingsStore
    private let mailNotificationPoster: MacOSAttentionNotificationPoster
    private let tunnelFailureHistoryStore: TunnelFailureHistoryStore
    private let startup = BridgeRuntimeStartup()
    private var runtime: BridgeRuntime?
    private var ipcServer: LocalBridgeIPCServer?
    private var runtimeTask: Task<BridgeRuntime, Error>?
    private var statusItem: NSStatusItem?
    private var statusMenuItems: StatusMenuItems?
    private var clientsMenuItem: NSMenuItem?
    private var tunnelMenuItem: NSMenuItem?
    private var mailNotificationsMenuItem: NSMenuItem?
    private var tunnelSupervisor: ChatGPTTunnelSupervisor?
    private var tunnelState: ChatGPTTunnelState?
    private var mailMonitor: MailMonitor?
    private var mailNotificationState: MailNotificationState = .off
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    init(
        configuration: BridgeLaunchConfiguration,
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        loginItemController: (any LoginItemControlling)? = SMAppLoginItemController(),
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(),
        mailMonitorSettingsStore: MailMonitorSettingsStore = MailMonitorSettingsStore(),
        mailNotificationPoster: MacOSAttentionNotificationPoster = MacOSAttentionNotificationPoster(),
        tunnelFailureHistoryStore: TunnelFailureHistoryStore = TunnelFailureHistoryStore()
    ) {
        self.configuration = configuration
        self.launchConfigurationStore = launchConfigurationStore
        self.loginItemController = loginItemController
        self.clientApprovalStore = clientApprovalStore
        self.mailMonitorSettingsStore = mailMonitorSettingsStore
        self.mailNotificationPoster = mailNotificationPoster
        self.tunnelFailureHistoryStore = tunnelFailureHistoryStore
    }

    static func run(configuration: BridgeLaunchConfiguration) async {
        let application = NSApplication.shared
        let host = MenuBarHost(configuration: configuration)
        application.setActivationPolicy(.accessory)
        application.delegate = host
        withExtendedLifetime(host) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MacMCP 🟡"
        let statusItems = StatusMenuItems()
        updateStatusMenu(
            statusItems,
            snapshot: .connected(
                mail: configuration.mailSidecarURL != nil,
                eventKit: configuration.eventKitSidecarURL != nil
            )
        )
        configureMailNotifications(statusItems.notifications)
        updateMailAccountsMenu(statusItems.mail, writableAccountIDs: [])
        configureLaunchAtLogin(statusItems.loginItem)
        configureChatGPTTunnel(statusItems.tunnel)
        statusMenuItems = statusItems
        clientsMenuItem = statusItems.clients
        Task { await refreshClientsMenu() }
        item.menu = makeMenu(statusItems: statusItems)
        statusItem = item

        runtimeTask = Task {
            try await BridgeRuntime.start(configuration: configuration, startup: startup)
        }
        startTask = Task { await startAndProbe(statusItems: statusItems) }
        refreshTask = Task { await refreshLoop() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime != nil || startTask != nil else {
            return .terminateNow
        }
        Task {
            await stopRuntime()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        startTask?.cancel()
        refreshTask?.cancel()
        Task { await mailMonitor?.stop() }
        Task { await tunnelSupervisor?.stop() }
    }

    func makeMenu(statusItems: StatusMenuItems) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for item in [statusItems.overall, statusItems.calendar, statusItems.reminders] {
            item.isEnabled = false
            menu.addItem(item)
        }
        statusItems.mail.isEnabled = true
        menu.insertItem(statusItems.mail, at: 1)
        statusItems.notifications.isEnabled = true
        menu.addItem(statusItems.notifications)
        statusItems.loginItem.isEnabled = false
        menu.addItem(statusItems.loginItem)
        statusItems.tunnel.isEnabled = true
        statusItems.tunnel.submenu = makeTunnelActionsMenu()
        menu.addItem(statusItems.tunnel)
        statusItems.clients.isEnabled = true
        menu.addItem(statusItems.clients)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshMenuState() }
    }

    private func startAndProbe(statusItems: StatusMenuItems) async {
        do {
            guard let runtimeTask else { return }
            let runtime = try await runtimeTask.value
            guard !Task.isCancelled else {
                await runtime.stop()
                return
            }
            self.runtime = runtime
            let ipcServer = await runtime.makeLocalIPCServer(
                clientApprovalStore: clientApprovalStore,
                onClientApprovalChanged: { [weak self] in
                    Task { @MainActor in
                        await self?.refreshClientsMenu()
                    }
                }
            )
            try ipcServer.start()
            self.ipcServer = ipcServer
            if let identity = LocalClientIdentity.currentProcess() {
                _ = try? await clientApprovalStore.approveAppOwnedTunnelProxy(identity)
                await refreshClientsMenu()
            }
            await tunnelSupervisor?.start()
            await runtime.waitForInitialHealthChecks()
            let snapshot = await runtime.statusSource.snapshot()
            updateStatusMenu(statusItems, snapshot: snapshot)
            await startConfiguredMailNotifications()
        } catch {
            updateStatusMenu(statusItems, snapshot: failedSnapshot())
        }
    }

    func updateStatusMenu(_ statusItems: StatusMenuItems, snapshot: BridgeStatus) {
        let marker = Self.marker(forOverallStatus: snapshot)
        statusItem?.button?.title = "MacMCP \(marker)"
        statusItems.overall.title = "\(marker) MacMCP: \(Self.overallLabel(for: snapshot))"
        statusItems.mail.title = Self.componentTitle("Mail", state: snapshot.mail)
        statusItems.calendar.title = Self.componentTitle("Calendar", state: snapshot.calendar)
        statusItems.reminders.title = Self.componentTitle("Reminders", state: snapshot.reminders)
    }

    func refreshMenuState() async {
        await refreshStatusMenu()
        await refreshMailAccountsMenu()
        await refreshClientsMenu()
        tunnelSupervisor?.refreshHealth()
        if let tunnelMenuItem {
            updateTunnelMenu(tunnelMenuItem, state: tunnelState)
        }
        if let mailNotificationsMenuItem {
            updateMailNotificationsMenu(mailNotificationsMenuItem)
        }
    }

    func refreshStatusMenu() async {
        guard let runtime, let statusMenuItems else { return }
        let snapshot = await runtime.statusSource.snapshot()
        updateStatusMenu(statusMenuItems, snapshot: snapshot)
    }

    func configureLaunchAtLogin(_ item: NSMenuItem) {
        let configured = (try? launchConfigurationStore.readConfiguration())?.launchAtLogin == true
        if configured, let loginItemController {
            switch loginItemController.status {
            case .notRegistered, .notFound:
                // Replacing an ad-hoc-signed app invalidates its old service entry.
                try? loginItemController.register()
            case .enabled, .requiresApproval, .unavailable:
                break
            }
        }
        updateLoginItemMenu(item, status: loginItemController?.status ?? .unavailable)
    }

    static func loginItemTitle(status: LoginItemStatus) -> String {
        switch status {
        case .enabled:
            return "🟢 Launch at Login: enabled"
        case .notRegistered:
            return "⚪ Launch at Login: not registered"
        case .requiresApproval:
            return "🟡 Launch at Login: needs approval"
        case .notFound:
            return "🔴 Launch at Login: not found"
        case .unavailable:
            return "🔴 Launch at Login: unavailable"
        }
    }

    static func chatGPTTunnelTitle(state: ChatGPTTunnelState?) -> String {
        switch state {
        case .none:
            return "⚪ ChatGPT Tunnel: not configured"
        case .some(.starting):
            return "🟡 ChatGPT Tunnel: starting"
        case .some(.running):
            return "🟢 ChatGPT Tunnel: running"
        case .some(.unavailable):
            return "🔴 ChatGPT Tunnel: unavailable"
        }
    }

    private func updateLoginItemMenu(_ item: NSMenuItem, status: LoginItemStatus) {
        item.title = Self.loginItemTitle(status: status)
    }

    private func configureChatGPTTunnel(_ item: NSMenuItem) {
        tunnelMenuItem = item
        do {
            guard let tunnel = try launchConfigurationStore.readConfiguration()?.chatGPTTunnel,
                  let executableURL = Bundle.main.executableURL
            else {
                updateTunnelMenu(item, state: nil)
                return
            }
            let supervisor = ChatGPTTunnelSupervisor(
                configuration: tunnel,
                bridgeExecutableURL: executableURL,
                ipcSocketURL: LocalBridgeIPC.defaultSocketURL(),
                proxyWrapperURL: ChatGPTTunnelSupervisor.defaultProxyWrapperURL(),
                failureHistoryStore: tunnelFailureHistoryStore,
                onStateChanged: { [weak self] state in
                    self?.tunnelState = state
                    if let item = self?.tunnelMenuItem {
                        self?.updateTunnelMenu(item, state: state)
                        self?.refreshTunnelActionsMenu(item)
                    }
                }
            )
            tunnelSupervisor = supervisor
            tunnelState = .starting
            updateTunnelMenu(item, state: .starting)
        } catch {
            tunnelState = .unavailable
            updateTunnelMenu(item, state: .unavailable)
        }
    }

    private func updateTunnelMenu(_ item: NSMenuItem, state: ChatGPTTunnelState?) {
        item.title = Self.chatGPTTunnelTitle(state: state)
    }

    private func refreshTunnelActionsMenu(_ item: NSMenuItem) {
        item.submenu = makeTunnelActionsMenu()
    }

    private func configureMailNotifications(_ item: NSMenuItem) {
        mailNotificationsMenuItem = item
        do {
            mailNotificationState = try mailMonitorSettingsStore.read().enabled ? .starting : .off
        } catch {
            mailNotificationState = .unavailable
        }
        updateMailNotificationsMenu(item)
    }

    private func refreshMailAccountsMenu() async {
        guard let statusMenuItems else { return }
        let writableAccountIDs = await runtime?.mailActionAccess.writableAccountIDs() ?? []
        updateMailAccountsMenu(statusMenuItems.mail, writableAccountIDs: writableAccountIDs)
    }

    func updateMailAccountsMenu(_ item: NSMenuItem, writableAccountIDs: Set<String>) {
        let submenu = NSMenu()
        guard !configuration.mailAccounts.isEmpty else {
            let empty = NSMenuItem(title: "Accounts: none", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            item.submenu = submenu
            return
        }

        for account in configuration.mailAccounts {
            let accountItem = NSMenuItem(title: account.username, action: nil, keyEquivalent: "")
            let accountMenu = NSMenu()
            let readOnly = NSMenuItem(
                title: "Read only",
                action: #selector(toggleMailAccountReadOnly),
                keyEquivalent: ""
            )
            readOnly.target = self
            readOnly.representedObject = account.id
            readOnly.state = writableAccountIDs.contains(account.id) ? .off : .on
            accountMenu.addItem(readOnly)
            accountItem.submenu = accountMenu
            submenu.addItem(accountItem)
        }
        item.submenu = submenu
    }

    static func mailNotificationTitle(state: MailNotificationState) -> String {
        switch state {
        case .off:
            return "⚪ Mail Notifications: off"
        case .starting:
            return "🟡 Mail Notifications: starting"
        case .monitoring:
            return "🟢 Mail Notifications: on"
        case .needsPermission:
            return "🟡 Mail Notifications: needs permission"
        case .unavailable:
            return "🔴 Mail Notifications: unavailable"
        }
    }

    private func updateMailNotificationsMenu(_ item: NSMenuItem) {
        item.title = Self.mailNotificationTitle(state: mailNotificationState)
        let submenu = NSMenu()
        let enable = NSMenuItem(
            title: "Enable Notifications",
            action: #selector(enableMailNotifications),
            keyEquivalent: ""
        )
        enable.target = self
        enable.isEnabled = mailNotificationState != .monitoring
        submenu.addItem(enable)

        let checkNow = NSMenuItem(
            title: "Check Mail Now",
            action: #selector(checkMailNotificationsNow),
            keyEquivalent: ""
        )
        checkNow.target = self
        checkNow.isEnabled = mailMonitor != nil
        submenu.addItem(checkNow)

        let disable = NSMenuItem(
            title: "Disable Notifications",
            action: #selector(disableMailNotifications),
            keyEquivalent: ""
        )
        disable.target = self
        disable.isEnabled = mailMonitor != nil || mailNotificationState == .starting || mailNotificationState == .needsPermission
        submenu.addItem(disable)
        item.submenu = submenu
    }

    private func startConfiguredMailNotifications() async {
        guard mailNotificationState == .starting else { return }
        await startMailNotifications(allowPrompt: false, persist: false)
    }

    private func startMailNotifications(allowPrompt: Bool, persist: Bool) async {
        guard let runtime, !configuration.mailAccounts.isEmpty else {
            mailNotificationState = .unavailable
            refreshMailNotificationsMenu()
            return
        }
        guard (await runtime.statusSource.snapshot()).mail == .ready else {
            mailNotificationState = .unavailable
            refreshMailNotificationsMenu()
            return
        }

        switch await mailNotificationPoster.authorize(allowPrompt: allowPrompt) {
        case .granted:
            break
        case .notDetermined:
            mailNotificationState = .needsPermission
            refreshMailNotificationsMenu()
            return
        case .denied:
            mailNotificationState = .unavailable
            refreshMailNotificationsMenu()
            return
        }

        do {
            let monitor = try runtime.makeMailMonitor(
                accountIDs: configuration.mailAccounts.map(\.id),
                notifications: mailNotificationPoster
            )
            mailMonitor = monitor
            await monitor.start()
            if persist {
                try mailMonitorSettingsStore.save(MailMonitorSettings(enabled: true))
            }
            mailNotificationState = .monitoring
        } catch {
            mailNotificationState = .unavailable
        }
        refreshMailNotificationsMenu()
    }

    private func stopMailNotifications() async {
        await mailMonitor?.stop()
        mailMonitor = nil
        do {
            try mailMonitorSettingsStore.save(MailMonitorSettings(enabled: false))
            mailNotificationState = .off
        } catch {
            mailNotificationState = .unavailable
        }
        refreshMailNotificationsMenu()
    }

    private func refreshMailNotificationsMenu() {
        if let mailNotificationsMenuItem {
            updateMailNotificationsMenu(mailNotificationsMenuItem)
        }
    }

    private func makeTunnelActionsMenu() -> NSMenu {
        let submenu = NSMenu()
        let history = NSMenuItem(title: tunnelFailureHistoryTitle(), action: nil, keyEquivalent: "")
        history.isEnabled = false
        submenu.addItem(history)
        submenu.addItem(.separator())
        if tunnelSupervisor != nil {
            let restart = NSMenuItem(
                title: "Restart Tunnel",
                action: #selector(restartChatGPTTunnel),
                keyEquivalent: ""
            )
            restart.target = self
            submenu.addItem(restart)
            let replaceKey = NSMenuItem(
                title: "Replace Runtime API Key...",
                action: #selector(replaceChatGPTTunnelKey),
                keyEquivalent: ""
            )
            replaceKey.target = self
            submenu.addItem(replaceKey)
            submenu.addItem(.separator())
        }
        let tunnelSettings = NSMenuItem(
            title: "Open Tunnel Settings",
            action: #selector(openTunnelSettings),
            keyEquivalent: ""
        )
        tunnelSettings.target = self
        submenu.addItem(tunnelSettings)
        let apiKeys = NSMenuItem(
            title: "Open Runtime API Keys",
            action: #selector(openTunnelAPIKeys),
            keyEquivalent: ""
        )
        apiKeys.target = self
        submenu.addItem(apiKeys)
        return submenu
    }

    private func tunnelFailureHistoryTitle() -> String {
        do {
            guard let latest = try tunnelFailureHistoryStore.read().last else {
                return "Recent failures: none"
            }
            return "Last failure: \(latest.occurredAt) \(latest.menuTitle)"
        } catch {
            return "Recent failures: unavailable"
        }
    }

    func refreshClientsMenu() async {
        guard let clientsMenuItem else { return }
        do {
            updateClientsMenu(clientsMenuItem, snapshot: try await clientApprovalStore.snapshot())
        } catch {
            clientsMenuItem.title = "🔴 Clients: unavailable"
            clientsMenuItem.submenu = nil
        }
    }

    func updateClientsMenu(_ item: NSMenuItem, snapshot: ClientApprovalSnapshot) {
        if snapshot.pending != nil {
            item.title = "🟡 Clients: approval needed"
        } else if snapshot.approved.isEmpty {
            item.title = "⚪ Clients: none approved"
        } else {
            item.title = "🟢 Clients: \(snapshot.approved.count) approved"
        }

        let submenu = NSMenu()
        if let pending = snapshot.pending {
            let approve = NSMenuItem(
                title: "Approve: \(clientPresentationName(identity: pending))",
                action: #selector(approvePendingClient),
                keyEquivalent: ""
            )
            approve.target = self
            submenu.addItem(approve)
            submenu.addItem(.separator())
        }

        if snapshot.approved.isEmpty {
            let empty = NSMenuItem(title: "Approved: none", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for client in snapshot.approved {
                let revoke = NSMenuItem(
                    title: "Revoke: \(clientPresentationName(identity: client.identity))",
                    action: #selector(revokeClient),
                    keyEquivalent: ""
                )
                revoke.target = self
                revoke.representedObject = client.fingerprint
                submenu.addItem(revoke)
            }
        }
        item.submenu = submenu
    }

    func clientPresentationName(identity: LocalClientIdentity) -> String {
        if identity.executablePath == Bundle.main.executableURL?.path {
            return "ChatGPT Tunnel Proxy"
        }
        if let mailSidecarURL = configuration.mailSidecarURL {
            let localProxyURL = mailSidecarURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("bin/mac-agent-bridge")
            if identity.executablePath == localProxyURL.path {
                return "Local MCP Proxy"
            }
        }
        return identity.displayName
    }

    static func componentTitle(_ name: String, state: BridgeStatus.ComponentState) -> String {
        "\(marker(for: state)) \(name): \(label(for: state))"
    }

    static func marker(for state: BridgeStatus.ComponentState) -> String {
        switch state {
        case .ready:
            return "🟢"
        case .connectedUnverified:
            return "🟡"
        case .unavailable:
            return "🔴"
        case .notConfigured:
            return "⚪"
        }
    }

    static func marker(forOverallStatus status: BridgeStatus) -> String {
        let states = [status.mail, status.calendar, status.reminders]
        if states.contains(.unavailable) { return "🔴" }
        if states.contains(.connectedUnverified) { return "🟡" }
        if states.contains(.ready) { return "🟢" }
        return "⚪"
    }

    static func label(for state: BridgeStatus.ComponentState) -> String {
        switch state {
        case .ready:
            return "ready"
        case .connectedUnverified:
            return "checking"
        case .unavailable:
            return "unavailable"
        case .notConfigured:
            return "not configured"
        }
    }

    static func overallLabel(for status: BridgeStatus) -> String {
        switch marker(forOverallStatus: status) {
        case "🟢":
            return "ready"
        case "🟡":
            return "checking"
        case "🔴":
            return "needs attention"
        default:
            return "not configured"
        }
    }

    private func failedSnapshot() -> BridgeStatus {
        BridgeStatus(
            version: AppVersion.version,
            mode: .reader,
            mail: configuration.mailSidecarURL == nil ? .notConfigured : .unavailable,
            calendar: configuration.eventKitSidecarURL == nil ? .notConfigured : .unavailable,
            reminders: configuration.eventKitSidecarURL == nil ? .notConfigured : .unavailable,
            mailRestartCount: 0,
            eventKitRestartCount: 0,
            writeCapabilitiesEnabled: false
        )
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }

    @objc func approvePendingClient() {
        Task { @MainActor in
            _ = try? await clientApprovalStore.approvePending()
            await refreshMenuState()
        }
    }

    @objc func revokeClient(_ sender: NSMenuItem) {
        guard let fingerprint = sender.representedObject as? String else { return }
        Task { @MainActor in
            try? await clientApprovalStore.revoke(fingerprint: fingerprint)
            await refreshMenuState()
        }
    }

    @objc func toggleMailAccountReadOnly(_ sender: NSMenuItem) {
        guard let accountID = sender.representedObject as? String,
              let runtime
        else { return }
        Task { @MainActor in
            let writableAccountIDs = await runtime.mailActionAccess.writableAccountIDs()
            do {
                try await runtime.mailActionAccess.setReadOnly(
                    writableAccountIDs.contains(accountID),
                    for: accountID
                )
                let updatedWritableAccountIDs = await runtime.mailActionAccess.writableAccountIDs()
                await runtime.statusSource.updateWriteCapabilitiesEnabled(!updatedWritableAccountIDs.isEmpty)
            } catch {
                // Keep the last persisted state visible if the settings file
                // cannot be changed.
            }
            await refreshMailAccountsMenu()
        }
    }

    @objc private func enableMailNotifications() {
        Task { await startMailNotifications(allowPrompt: true, persist: true) }
    }

    @objc private func disableMailNotifications() {
        Task { await stopMailNotifications() }
    }

    @objc private func checkMailNotificationsNow() {
        Task {
            guard let mailMonitor else { return }
            let summary = await mailMonitor.scanNow()
            mailNotificationState = summary.completedAccounts == 0 ? .unavailable : .monitoring
            refreshMailNotificationsMenu()
        }
    }

    @objc private func restartChatGPTTunnel() {
        Task { await tunnelSupervisor?.restart() }
    }

    @objc private func replaceChatGPTTunnelKey() {
        guard tunnelSupervisor != nil else { return }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Runtime API key"

        let alert = NSAlert()
        alert.messageText = "Replace Runtime API Key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var key = Data(field.stringValue.utf8)
        defer { key.resetBytes(in: 0..<key.count) }
        guard !key.isEmpty else { return }

        do {
            try KeychainCredentialStore(
                service: KeychainCredentialStore.chatGPTTunnelService
            ).storeSecret(key, account: KeychainCredentialStore.chatGPTTunnelAccount)
            Task { await tunnelSupervisor?.restart() }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Unable to store Runtime API Key"
            failure.informativeText = "Check Keychain access and try again."
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    @objc private func openTunnelSettings() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
    }

    @objc private func openTunnelAPIKeys() {
        NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshMenuState()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func stopRuntime() async {
        if let stopTask {
            await stopTask.value
            return
        }

        let task = Task { @MainActor in
            startTask?.cancel()
            refreshTask?.cancel()
            runtimeTask?.cancel()
            await mailMonitor?.stop()
            mailMonitor = nil
            await tunnelSupervisor?.stop()
            await startup.stop()
            await ipcServer?.stop()
            ipcServer = nil
            let runtimeToStop = runtime
            runtime = nil
            await runtimeToStop?.stop()
            if let runtimeTask {
                do {
                    let startedRuntime = try await runtimeTask.value
                    await startedRuntime.stop()
                } catch {}
            }
            runtimeTask = nil
            startTask = nil
            refreshTask = nil
        }
        stopTask = task
        await task.value
        stopTask = nil
    }
}
