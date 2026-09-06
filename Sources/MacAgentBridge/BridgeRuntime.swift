import Foundation

struct BridgeLaunchConfiguration: Equatable, Sendable {
    let mailSidecarURL: URL?
    let eventKitSidecarURL: URL?
    let mailAccounts: [MailAccountConfiguration]
    let menuBar: Bool

    init(
        mailSidecarURL: URL?,
        eventKitSidecarURL: URL?,
        mailAccounts: [MailAccountConfiguration],
        menuBar: Bool
    ) {
        self.mailSidecarURL = mailSidecarURL
        self.eventKitSidecarURL = eventKitSidecarURL
        self.mailAccounts = mailAccounts
        self.menuBar = menuBar
    }

    init(
        mailSidecarURL: URL?,
        eventKitSidecarURL: URL?,
        iCloudAddress: String?,
        menuBar: Bool
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
    }

    var hasSidecars: Bool { mailSidecarURL != nil || eventKitSidecarURL != nil }
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
    let policy: ReaderPolicy
    let statusSource: BridgeStatusSource
    let attachmentReader: AttachmentTextReader?
    private var mailHealthTask: Task<Void, Never>?
    private var eventKitHealthTask: Task<Void, Never>?
    private var recurringHealthTask: Task<Void, Never>?

    private init(
        supervisor: SidecarSupervisor,
        router: GatewayRouter,
        policy: ReaderPolicy,
        statusSource: BridgeStatusSource,
        attachmentReader: AttachmentTextReader?
    ) {
        self.supervisor = supervisor
        self.router = router
        self.policy = policy
        self.statusSource = statusSource
        self.attachmentReader = attachmentReader
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
        let supervisor = SidecarSupervisor { event in
            Task { await statusObserver.handle(event) }
        }
        let router = GatewayRouter()
        let policy = ReaderPolicy()
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

        do {
            try Task.checkCancellation()
            try await startup?.checkRunning()
            if let mailExecutable = configuration.mailSidecarURL {
                guard !configuration.mailAccounts.isEmpty else {
                    throw BridgeRuntimeError.missingMailAccounts
                }

                var accountSecrets: [MailAccountSecret] = []
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
                    attachmentDirectory: attachmentStorage?.directoryURL
                )
                defer { privateConfig.remove() }

                let io = try await supervisor.start(
                    SidecarSpec(
                        id: ReaderPolicy.mailSidecarID,
                        executableURL: mailExecutable,
                        arguments: [
                            "--transport", "stdio",
                            "--config", privateConfig.fileURL.path,
                            "--log-level", "warn"
                        ],
                        // A restart needs a freshly materialized Keychain secret and
                        // a new MCP client. Until that orchestration exists, fail
                        // closed instead of leaving a secret file on disk.
                        restartPolicy: .onUnexpectedExit(maxAttempts: 3, initialDelayMilliseconds: 500)
                    )
                )
                try await router.attach(
                    sidecarID: ReaderPolicy.mailSidecarID,
                    client: SidecarMCPClient(id: ReaderPolicy.mailSidecarID, io: io),
                    policy: policy
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
                    policy: policy
                )
            }
        } catch {
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
            statusSource: statusSource,
            attachmentReader: attachmentStorage.map {
                AttachmentTextReader(router: router, policy: policy, storage: $0)
            }
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
        let tools = (BridgeServer.defineTools() + (await router.tools()))
            .sorted { $0.name < $1.name }
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

    func waitForInitialHealthChecks() async {
        await mailHealthTask?.value
        await eventKitHealthTask?.value
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
