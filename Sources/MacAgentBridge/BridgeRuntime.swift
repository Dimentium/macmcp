import Foundation
import MCP

struct BridgeLaunchConfiguration: Equatable, Sendable {
    let mailSidecarURL: URL?
    let eventKitSidecarURL: URL?
    let mailAccounts: [MailAccountConfiguration]
    let menuBar: Bool
    let localMailActions: Bool

    init(
        mailSidecarURL: URL?,
        eventKitSidecarURL: URL?,
        mailAccounts: [MailAccountConfiguration],
        menuBar: Bool,
        localMailActions: Bool = false
    ) {
        self.mailSidecarURL = mailSidecarURL
        self.eventKitSidecarURL = eventKitSidecarURL
        self.mailAccounts = mailAccounts
        self.menuBar = menuBar
        self.localMailActions = localMailActions
    }

    init(
        mailSidecarURL: URL?,
        eventKitSidecarURL: URL?,
        iCloudAddress: String?,
        menuBar: Bool,
        localMailActions: Bool = false
    ) {
        self.mailSidecarURL = mailSidecarURL
        self.eventKitSidecarURL = eventKitSidecarURL
        if let iCloudAddress,
           let account = try? MailAccountConfiguration.iCloud(address: iCloudAddress) {
            self.mailAccounts = [account]
        } else {
            self.mailAccounts = []
        }
        self.menuBar = menuBar
        self.localMailActions = localMailActions
    }

    var hasSidecars: Bool { mailSidecarURL != nil || eventKitSidecarURL != nil }
    var requiresAppOwnedRuntime: Bool { hasSidecars && !menuBar }
    var iCloudAddress: String? {
        mailAccounts.first { $0.id == "icloud" }?.username
    }
}

actor BridgeRuntimeStartup {
    private var supervisor: SidecarSupervisor?
    private var router: GatewayRouter?
    private var stopRequested = false

    func bind(supervisor: SidecarSupervisor, router: GatewayRouter) throws {
        guard !stopRequested else {
            throw CancellationError()
        }
        self.supervisor = supervisor
        self.router = router
    }

    func stop() async {
        stopRequested = true
        await router?.detach(sidecarID: ReaderPolicy.mailSidecarID)
        await router?.detach(sidecarID: ReaderPolicy.eventKitSidecarID)
        await supervisor?.stopAll()
    }

    func checkRunning() throws {
        if stopRequested {
            throw CancellationError()
        }
    }

    func snapshots() async -> [SidecarSnapshot] {
        await supervisor?.snapshots() ?? []
    }
}

enum BridgeRuntimeError: LocalizedError, Equatable {
    case missingMailAccounts

    var errorDescription: String? {
        switch self {
        case .missingMailAccounts:
            return "At least one mail account is required when --mail-sidecar is configured"
        }
    }
}

final class BridgeRuntime {
    let supervisor: SidecarSupervisor
    let router: GatewayRouter
    // policy is the immutable reader surface used by the standard local MCP
    // socket, stdio bridge, monitor, and ChatGPT tunnel.
    let policy: ReaderPolicy
    let localMailActionPolicy: ReaderPolicy?
    private let routingPolicy: ReaderPolicy
    let statusSource: BridgeStatusSource
    let attachmentReader: AttachmentTextReader?
    private var mailSidecarConfiguration: MaterializedMailConfiguration?
    private var mailHealthTask: Task<Void, Never>?
    private var eventKitHealthTask: Task<Void, Never>?
    private var recurringHealthTask: Task<Void, Never>?

    private init(
        supervisor: SidecarSupervisor,
        router: GatewayRouter,
        policy: ReaderPolicy,
        localMailActionPolicy: ReaderPolicy?,
        routingPolicy: ReaderPolicy,
        statusSource: BridgeStatusSource,
        attachmentReader: AttachmentTextReader?,
        mailSidecarConfiguration: MaterializedMailConfiguration?
    ) {
        self.supervisor = supervisor
        self.router = router
        self.policy = policy
        self.localMailActionPolicy = localMailActionPolicy
        self.routingPolicy = routingPolicy
        self.statusSource = statusSource
        self.attachmentReader = attachmentReader
        self.mailSidecarConfiguration = mailSidecarConfiguration
    }

    deinit {
        // A caller that abandons a partially started runtime must not leave a
        // Keychain-derived mail configuration on disk.
        mailSidecarConfiguration?.remove()
    }

    static func start(
        configuration: BridgeLaunchConfiguration,
        credentials: any CredentialStore = KeychainCredentialStore(),
        startup: BridgeRuntimeStartup? = nil
    ) async throws -> BridgeRuntime {
        let statusSource = BridgeStatusSource(
            status: .connected(
                mail: configuration.mailSidecarURL != nil,
                eventKit: configuration.eventKitSidecarURL != nil
            )
        )
        let statusObserver = SidecarStatusObserver(statusSource: statusSource)
        let runtimeObserver = SidecarRuntimeObserver(statusObserver: statusObserver)
        let supervisor = SidecarSupervisor { event in
            Task { await runtimeObserver.handle(event) }
        }
        let router = GatewayRouter()
        let policy = ReaderPolicy()
        let localMailActionPolicy = configuration.localMailActions
            ? ReaderPolicy(rules: ReaderPolicy.localMailActionRules)
            : nil
        let routingPolicy = ReaderPolicy(
            rules: ReaderPolicy.rules + (configuration.localMailActions ? ReaderPolicy.localMailActionRules : [])
        )
        await runtimeObserver.bind(supervisor: supervisor, router: router, policy: routingPolicy)
        try Task.checkCancellation()
        try await startup?.bind(supervisor: supervisor, router: router)

        let attachmentStorage: AttachmentStorage?
        if configuration.mailSidecarURL != nil {
            let storage = AttachmentStorage()
            try storage.prepare()
            attachmentStorage = storage
        } else {
            attachmentStorage = nil
        }

        var materializedMailConfiguration: MaterializedMailConfiguration?
        do {
            try Task.checkCancellation()
            try await startup?.checkRunning()
            if let mailExecutable = configuration.mailSidecarURL {
                guard !configuration.mailAccounts.isEmpty else {
                    throw BridgeRuntimeError.missingMailAccounts
                }

                var accountSecrets: [MailAccountSecret] = []
                let managedDraftKey = configuration.localMailActions
                    ? try ManagedDraftKeyStore().loadOrCreate()
                    : nil
                defer {
                    if var managedDraftKey {
                        managedDraftKey.resetBytes(in: 0..<managedDraftKey.count)
                    }
                }
                for account in configuration.mailAccounts {
                    let password = try credentials.readSecret(account: account.username)
                    accountSecrets.append(
                        MailAccountSecret(configuration: account, password: password)
                    )
                }
                defer {
                    for index in accountSecrets.indices {
                        accountSecrets[index].password.resetBytes(in: 0..<accountSecrets[index].password.count)
                    }
                }
                let privateConfig = try MailSidecarConfigurationMaterializer().materialize(
                    accounts: accountSecrets,
                    attachmentDirectory: attachmentStorage?.directoryURL,
                    managedDraftKey: managedDraftKey
                )
                materializedMailConfiguration = privateConfig

                let io = try await supervisor.start(
                    SidecarSpec(
                        id: ReaderPolicy.mailSidecarID,
                        executableURL: mailExecutable,
                        arguments: [
                            "--transport", "stdio",
                            "--config", privateConfig.fileURL.path,
                            "--log-level", "warn"
                        ],
                        // The private config remains available only while this
                        // runtime owns the sidecar, so a supervised restart can
                        // reconnect without re-reading Keychain secrets.
                        restartPolicy: .onUnexpectedExit(maxAttempts: 3, initialDelayMilliseconds: 500)
                    )
                )
                try await router.attach(
                    sidecarID: ReaderPolicy.mailSidecarID,
                    client: SidecarMCPClient(id: ReaderPolicy.mailSidecarID, io: io),
                    policy: routingPolicy
                )
            }

            try Task.checkCancellation()
            try await startup?.checkRunning()
            if let eventKitExecutable = configuration.eventKitSidecarURL {
                let io = try await supervisor.start(
                    SidecarSpec(
                        id: ReaderPolicy.eventKitSidecarID,
                        executableURL: eventKitExecutable,
                        environment: ["CHE_ICAL_MCP_NO_BANNER": "1"],
                        restartPolicy: .onUnexpectedExit(maxAttempts: 3, initialDelayMilliseconds: 500)
                    )
                )
                try await router.attach(
                    sidecarID: ReaderPolicy.eventKitSidecarID,
                    client: SidecarMCPClient(id: ReaderPolicy.eventKitSidecarID, io: io),
                    policy: routingPolicy
                )
            }
        } catch {
            materializedMailConfiguration?.remove()
            attachmentStorage?.clear()
            await router.detach(sidecarID: ReaderPolicy.mailSidecarID)
            await router.detach(sidecarID: ReaderPolicy.eventKitSidecarID)
            await supervisor.stopAll()
            throw error
        }

        let runtime = BridgeRuntime(
            supervisor: supervisor,
            router: router,
            policy: policy,
            localMailActionPolicy: localMailActionPolicy,
            routingPolicy: routingPolicy,
            statusSource: statusSource,
            attachmentReader: attachmentStorage.map {
                AttachmentTextReader(router: router, policy: policy, storage: $0)
            },
            mailSidecarConfiguration: materializedMailConfiguration
        )
        runtime.startHealthChecks(
            mailConfigured: configuration.mailSidecarURL != nil,
            eventKitConfigured: configuration.eventKitSidecarURL != nil
        )
        return runtime
    }

    func makeServer() async -> BridgeServer {
        await BridgeServer(
            router: router,
            policy: policy,
            statusSource: statusSource,
            attachmentReader: attachmentReader
        )
    }

    func makeLocalIPCServer(
        socketURL: URL = LocalBridgeIPC.defaultSocketURL(),
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(),
        onClientApprovalChanged: (@Sendable () -> Void)? = nil
    ) async -> LocalBridgeIPCServer {
        let tools = await localTools(for: policy)
        return LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: tools,
            router: router,
            policy: policy,
            statusSource: statusSource,
            attachmentReader: attachmentReader,
            clientApprovalStore: clientApprovalStore,
            onClientApprovalChanged: onClientApprovalChanged
        )
    }

    func makeLocalMailActionIPCServer(
        socketURL: URL = LocalBridgeIPC.localMailActionSocketURL(),
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(
            fileURL: ClientApprovalStore.localMailActionFileURL()
        ),
        onClientApprovalChanged: (@Sendable () -> Void)? = nil
    ) async -> LocalBridgeIPCServer? {
        guard let localMailActionPolicy else { return nil }
        return LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: await localTools(for: localMailActionPolicy),
            router: router,
            policy: localMailActionPolicy,
            statusSource: statusSource,
            clientApprovalStore: clientApprovalStore,
            onClientApprovalChanged: onClientApprovalChanged
        )
    }

    func waitForInitialHealthChecks() async {
        await mailHealthTask?.value
        await eventKitHealthTask?.value
    }

    func makeMailMonitor(
        accountIDs: [String],
        notifications: any AttentionNotificationPosting,
        stateStore: MonitorStateStore? = nil
    ) throws -> MailMonitor {
        let resolvedStateStore: MonitorStateStore
        if let stateStore {
            resolvedStateStore = stateStore
        } else {
            resolvedStateStore = try MonitorStateStore(
                fileURL: MonitorStateStore.defaultFileURL()
            )
        }
        let scanner = MailScanner(
            router: router,
            policy: policy,
            state: resolvedStateStore,
            notifications: notifications
        )
        return MailMonitor(scanner: scanner, accountIDs: accountIDs)
    }

    func stop() async {
        let healthTasks = [mailHealthTask, eventKitHealthTask, recurringHealthTask]
        mailHealthTask = nil
        eventKitHealthTask = nil
        recurringHealthTask = nil
        healthTasks.forEach { $0?.cancel() }
        await router.detach(sidecarID: ReaderPolicy.mailSidecarID)
        await router.detach(sidecarID: ReaderPolicy.eventKitSidecarID)
        await supervisor.stopAll()
        mailSidecarConfiguration?.remove()
        mailSidecarConfiguration = nil
        attachmentReader?.storage.clear()
        for task in healthTasks {
            await task?.value
        }
    }

    private func startHealthChecks(mailConfigured: Bool, eventKitConfigured: Bool) {
        let mailProber = mailConfigured ? makeMailHealthProber() : nil
        let eventKitProber = eventKitConfigured ? makeEventKitHealthProber() : nil

        if let mailProber {
            mailHealthTask = Task { _ = await mailProber.probe() }
        }
        if let eventKitProber {
            eventKitHealthTask = Task { await eventKitProber.run() }
        }

        guard mailProber != nil || eventKitProber != nil else { return }
        recurringHealthTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                if let mailProber {
                    _ = await mailProber.probe()
                }
                if let eventKitProber {
                    await eventKitProber.run()
                }
            }
        }
    }

    private func localTools(for policy: ReaderPolicy) async -> [Tool] {
        let policyTools = await router.tools().filter { policy.publicToolNames.contains($0.name) }
        return (BridgeServer.defineTools() + policyTools).sorted { $0.name < $1.name }
    }

    private func makeMailHealthProber() -> MailHealthProber {
        let router = self.router
        let policy = self.policy
        let statusSource = self.statusSource
        let supervisor = self.supervisor
        return MailHealthProber(
            statusSource: statusSource,
            callTool: { publicName, arguments in
                try await router.call(
                    publicName: publicName,
                    arguments: arguments,
                    policy: policy
                )
            },
            onTimeout: {
                await router.detach(sidecarID: ReaderPolicy.mailSidecarID)
                try? await supervisor.stop(id: ReaderPolicy.mailSidecarID)
            }
        )
    }

    private func makeEventKitHealthProber() -> EventKitHealthProber {
        let router = self.router
        let policy = self.policy
        let statusSource = self.statusSource
        let supervisor = self.supervisor
        return EventKitHealthProber(
            statusSource: statusSource,
            callTool: { publicName, arguments in
                try await router.call(
                    publicName: publicName,
                    arguments: arguments,
                    policy: policy
                )
            },
            onTimeout: {
                await router.detach(sidecarID: ReaderPolicy.eventKitSidecarID)
                try? await supervisor.stop(id: ReaderPolicy.eventKitSidecarID)
            }
        )
    }
}
