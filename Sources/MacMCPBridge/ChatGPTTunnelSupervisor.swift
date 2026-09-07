import Foundation

private final class HealthProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    @discardableResult
    func finish(_ value: Bool, continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume(returning: value)
        return true
    }
}

@MainActor
enum ChatGPTTunnelState: Equatable, Sendable {
    case starting
    case running
    case unavailable
}

@MainActor
final class ChatGPTTunnelSupervisor {
    typealias StateHandler = @MainActor @Sendable (ChatGPTTunnelState) -> Void
    typealias HealthProbe = (_ clientPath: String, _ runtimeKey: String) async -> Bool

    private enum Phase {
        case initialize
        case doctor
        case run

        var diagnosticPhase: ChatGPTTunnelPhase {
            switch self {
            case .initialize:
                return .initialize
            case .doctor:
                return .doctor
            case .run:
                return .run
            }
        }
    }

    private let configuration: ChatGPTTunnelConfiguration
    private let bridgeExecutableURL: URL
    private let ipcSocketURL: URL
    private let proxyWrapperURL: URL
    private let credentialStore: any CredentialStore
    private let failureHistoryStore: TunnelFailureHistoryStore
    private let tunnelLogStore: TunnelClientLogStore
    private let healthProbe: HealthProbe
    private let onStateChanged: StateHandler
    private var activeProcess: Process?
    private var activeLogCapture: TunnelClientLogCapture?
    private var runtimeKey: String?
    private var generation = 0
    private var stopped = false
    private var tunnelClientIsRunning = false
    private var tunnelRunStartedAt: Date?
    private var hasCompletedControlPlanePoll = false
    private var healthProbeToken: UUID?
    private var healthProbeTimeoutTask: Task<Void, Never>?
    private var lastHealthProbeAt: Date?

    private let healthProbeInterval: TimeInterval = 5
    private let initialHealthProbeGracePeriod: TimeInterval = 60
    private let healthProbeTimeoutNanoseconds: UInt64
    private var lifecycleGeneration = 0

    private(set) var state: ChatGPTTunnelState = .starting {
        didSet { onStateChanged(state) }
    }

    static func defaultProxyWrapperURL(homeDirectory: URL = LocalUserPaths.homeDirectoryURL()) -> URL {
        MacMCPPaths.runtimeCacheDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("chatgpt-tunnel-proxy")
    }

    init(
        configuration: ChatGPTTunnelConfiguration,
        bridgeExecutableURL: URL,
        ipcSocketURL: URL,
        proxyWrapperURL: URL,
        credentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel(),
        failureHistoryStore: TunnelFailureHistoryStore = TunnelFailureHistoryStore(),
        tunnelLogStore: TunnelClientLogStore = TunnelClientLogStore(),
        healthProbe: @escaping HealthProbe = ChatGPTTunnelSupervisor.defaultHealthProbe,
        healthProbeTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onStateChanged: @escaping StateHandler = { _ in }
    ) {
        self.configuration = configuration
        self.bridgeExecutableURL = bridgeExecutableURL
        self.ipcSocketURL = ipcSocketURL
        self.proxyWrapperURL = proxyWrapperURL
        self.credentialStore = credentialStore
        self.failureHistoryStore = failureHistoryStore
        self.tunnelLogStore = tunnelLogStore
        self.healthProbe = healthProbe
        self.healthProbeTimeoutNanoseconds = healthProbeTimeoutNanoseconds
        self.onStateChanged = onStateChanged
    }

    func start() async {
        lifecycleGeneration += 1
        let currentLifecycleGeneration = lifecycleGeneration
        let previousProcess = invalidateActiveRun()
        await terminate(previousProcess)
        guard currentLifecycleGeneration == lifecycleGeneration else { return }

        stopped = false
        tunnelClientIsRunning = false
        tunnelRunStartedAt = nil
        hasCompletedControlPlanePoll = false
        generation += 1
        let currentGeneration = generation
        state = .starting

        guard FileManager.default.isExecutableFile(atPath: configuration.clientPath) else {
            becomeUnavailable(phase: .prerequisites, reason: .clientUnavailable)
            return
        }
        guard FileManager.default.fileExists(atPath: ipcSocketURL.path) else {
            becomeUnavailable(phase: .prerequisites, reason: .ipcUnavailable)
            return
        }
        do {
            try writeProxyWrapper()
        } catch {
            becomeUnavailable(phase: .prerequisites, reason: .proxySetupFailed)
            return
        }
        do {
            var key = try credentialStore.readSecret(
                account: KeychainCredentialStore.chatGPTTunnelAccount
            )
            runtimeKey = String(decoding: key, as: UTF8.self)
            key.resetBytes(in: 0..<key.count)
        } catch {
            runtimeKey = nil
            becomeUnavailable(phase: .credential, reason: .credentialUnavailable)
            return
        }
        guard let runtimeKey, !runtimeKey.isEmpty else {
            becomeUnavailable(phase: .credential, reason: .credentialMissing)
            return
        }
        launch(
            phase: .initialize,
            arguments: [
                "init",
                "--sample", "sample_mcp_stdio_local",
                "--profile", configuration.profile,
                "--tunnel-id", configuration.tunnelID,
                "--mcp-command", proxyWrapperURL.path,
                "--force"
            ],
            generation: currentGeneration
        )
    }

    func restart() async {
        await start()
    }

    func stop() async {
        lifecycleGeneration += 1
        let process = invalidateActiveRun()
        await terminate(process)
    }

    private func invalidateActiveRun() -> Process? {
        stopped = true
        generation += 1
        tunnelClientIsRunning = false
        tunnelRunStartedAt = nil
        hasCompletedControlPlanePoll = false
        healthProbeToken = nil
        healthProbeTimeoutTask?.cancel()
        healthProbeTimeoutTask = nil
        lastHealthProbeAt = nil
        let process = activeProcess
        activeProcess = nil
        runtimeKey = nil
        return process
    }

    private func launch(phase: Phase, arguments: [String], generation: Int) {
        guard generation == self.generation, !stopped, let runtimeKey else { return }

        let process = Process()
        let logCapture = TunnelClientLogCapture(store: tunnelLogStore)
        process.executableURL = URL(fileURLWithPath: configuration.clientPath)
        process.arguments = arguments
        process.environment = [
            "HOME": LocalUserPaths.homeDirectoryURL().path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "CONTROL_PLANE_API_KEY": runtimeKey,
            "LOG_FORMAT": "json",
            "LOG_LEVEL": "info"
        ]
        process.standardOutput = logCapture.standardOutput
        process.standardError = logCapture.standardError
        process.terminationHandler = { [weak self] completed in
            logCapture.finish()
            self?.tunnelLogStore.recordLifecycle(
                "tunnel-client \(phase.diagnosticPhase.rawValue) exited with status \(completed.terminationStatus)"
            )
            Task { @MainActor in
                self?.didFinish(
                    phase: phase,
                    status: completed.terminationStatus,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
            logCapture.closeParentWriteHandles()
            activeProcess = process
            activeLogCapture = logCapture
            tunnelLogStore.recordLifecycle("tunnel-client \(phase.diagnosticPhase.rawValue) started")
            if phase == .run {
                tunnelClientIsRunning = true
                tunnelRunStartedAt = Date()
                hasCompletedControlPlanePoll = false
                state = .starting
                refreshHealth(force: true)
            }
        } catch {
            logCapture.closeParentWriteHandles()
            logCapture.finish()
            tunnelLogStore.recordLifecycle("tunnel-client \(phase.diagnosticPhase.rawValue) failed to start")
            becomeUnavailable(phase: phase.diagnosticPhase, reason: .processLaunchFailed)
        }
    }

    private func didFinish(phase: Phase, status: Int32, generation: Int) {
        // stop() and restart() invalidate the generation before terminating
        // the process, so expected exits never enter failure history.
        guard generation == self.generation, !stopped else { return }
        activeProcess = nil
        if phase == .run {
            tunnelClientIsRunning = false
            tunnelRunStartedAt = nil
            hasCompletedControlPlanePoll = false
        }
        guard status == 0 else {
            runtimeKey = nil
            becomeUnavailable(phase: phase.diagnosticPhase, reason: .processExited)
            return
        }

        switch phase {
        case .initialize:
            launch(
                phase: .doctor,
                arguments: ["doctor", "--profile", configuration.profile, "--explain"],
                generation: generation
            )
        case .doctor:
            launch(
                phase: .run,
                arguments: ["run", "--profile", configuration.profile],
                generation: generation
            )
        case .run:
            runtimeKey = nil
            becomeUnavailable(phase: .run, reason: .processExited)
        }
    }

    func refreshHealth(force: Bool = false) {
        guard !stopped, tunnelClientIsRunning else { return }
        guard activeProcess?.isRunning == true else {
            becomeUnavailable(phase: .run, reason: .processExited)
            return
        }
        guard let runtimeKey else {
            becomeUnavailable(phase: .credential, reason: .credentialMissing)
            return
        }
        guard healthProbeToken == nil else { return }
        if !force,
           let lastHealthProbeAt,
           Date().timeIntervalSince(lastHealthProbeAt) < healthProbeInterval {
            return
        }

        let token = UUID()
        healthProbeToken = token
        lastHealthProbeAt = Date()
        let currentGeneration = generation
        let healthProbe = healthProbe
        let clientPath = configuration.clientPath
        let healthProbeTimeoutNanoseconds = self.healthProbeTimeoutNanoseconds
        healthProbeTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: healthProbeTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  currentGeneration == self.generation,
                  !self.stopped,
                  self.healthProbeToken == token
            else {
                return
            }
            self.healthProbeToken = nil
            self.healthProbeTimeoutTask = nil
            self.becomeUnavailable(phase: .health, reason: .healthTimedOut)
        }
        Task { [weak self] in
            let isHealthy = await healthProbe(clientPath, runtimeKey)
            guard let self,
                  currentGeneration == self.generation,
                  !self.stopped,
                  self.healthProbeToken == token
            else {
                return
            }
            self.healthProbeToken = nil
            self.healthProbeTimeoutTask?.cancel()
            self.healthProbeTimeoutTask = nil
            if isHealthy {
                self.hasCompletedControlPlanePoll = true
                self.state = .running
            } else if !self.hasCompletedControlPlanePoll,
                      let tunnelRunStartedAt = self.tunnelRunStartedAt,
                      Date().timeIntervalSince(tunnelRunStartedAt) < self.initialHealthProbeGracePeriod {
                self.state = .starting
            } else {
                self.becomeUnavailable(phase: .health, reason: .healthUnavailable)
            }
        }
    }

    private func becomeUnavailable(
        phase: ChatGPTTunnelPhase,
        reason: ChatGPTTunnelFailureReason
    ) {
        guard state != .unavailable else { return }
        try? failureHistoryStore.record(.now(phase: phase, reason: reason))
        state = .unavailable
    }

    nonisolated static func defaultHealthProbe(clientPath: String, runtimeKey: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            let completion = HealthProcessCompletion()
            process.executableURL = URL(fileURLWithPath: clientPath)
            process.arguments = [
                "health",
                "--port", "8080",
                "--require-control-plane-poll",
                "--json"
            ]
            process.environment = [
                "HOME": LocalUserPaths.homeDirectoryURL().path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                "CONTROL_PLANE_API_KEY": runtimeKey
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completed in
                _ = completion.finish(
                    completed.terminationStatus == 0,
                    continuation: continuation
                )
            }
            do {
                try process.run()
            } catch {
                _ = completion.finish(false, continuation: continuation)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                guard completion.finish(false, continuation: continuation) else { return }
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }

    private func terminate(_ process: Process?) async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            await waitForExit(process, timeoutNanoseconds: 2_000_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            await waitForExit(process, timeoutNanoseconds: 2_000_000_000)
        }
    }

    private func waitForExit(_ process: Process, timeoutNanoseconds: UInt64) async {
        let interval: UInt64 = 50_000_000
        var elapsed: UInt64 = 0
        while process.isRunning && elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
    }

    private func writeProxyWrapper() throws {
        let directoryURL = proxyWrapperURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let source = """
        #!/bin/bash
        set -euo pipefail
        exec env MACMCP_TUNNEL_PROXY=1 \(shellQuote(bridgeExecutableURL.path)) --stdio-proxy \(shellQuote(ipcSocketURL.path))
        """
        try Data((source + "\n").utf8).write(to: proxyWrapperURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: proxyWrapperURL.path
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
    }
}
