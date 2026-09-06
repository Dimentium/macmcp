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
    typealias HealthProbe = (_ clientPath: String) async -> Bool

    private enum Phase {
        case initialize
        case doctor
        case run
    }

    private let configuration: ChatGPTTunnelConfiguration
    private let bridgeExecutableURL: URL
    private let ipcSocketURL: URL
    private let proxyWrapperURL: URL
    private let credentialStore: any CredentialStore
    private let healthProbe: HealthProbe
    private let onStateChanged: StateHandler
    private var activeProcess: Process?
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
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("MacMCP", isDirectory: true)
            .appendingPathComponent("chatgpt-tunnel-proxy")
    }

    init(
        configuration: ChatGPTTunnelConfiguration,
        bridgeExecutableURL: URL,
        ipcSocketURL: URL,
        proxyWrapperURL: URL,
        credentialStore: any CredentialStore = KeychainCredentialStore(
            service: KeychainCredentialStore.chatGPTTunnelService
        ),
        healthProbe: @escaping HealthProbe = ChatGPTTunnelSupervisor.defaultHealthProbe,
        healthProbeTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onStateChanged: @escaping StateHandler = { _ in }
    ) {
        self.configuration = configuration
        self.bridgeExecutableURL = bridgeExecutableURL
        self.ipcSocketURL = ipcSocketURL
        self.proxyWrapperURL = proxyWrapperURL
        self.credentialStore = credentialStore
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

        do {
            guard FileManager.default.isExecutableFile(atPath: configuration.clientPath),
                  FileManager.default.fileExists(atPath: ipcSocketURL.path)
            else {
                state = .unavailable
                return
            }
            try writeProxyWrapper()
            var key = try credentialStore.readSecret(
                account: KeychainCredentialStore.chatGPTTunnelAccount
            )
            runtimeKey = String(decoding: key, as: UTF8.self)
            key.resetBytes(in: 0..<key.count)
            guard let runtimeKey, !runtimeKey.isEmpty else {
                state = .unavailable
                return
            }
            state = .starting
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
        } catch {
            runtimeKey = nil
            state = .unavailable
        }
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
        process.executableURL = URL(fileURLWithPath: configuration.clientPath)
        process.arguments = arguments
        process.environment = [
            "HOME": LocalUserPaths.homeDirectoryURL().path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "CONTROL_PLANE_API_KEY": runtimeKey
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] completed in
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
            activeProcess = process
            if phase == .run {
                tunnelClientIsRunning = true
                tunnelRunStartedAt = Date()
                hasCompletedControlPlanePoll = false
                state = .starting
                refreshHealth(force: true)
            }
        } catch {
            state = .unavailable
        }
    }

    private func didFinish(phase: Phase, status: Int32, generation: Int) {
        guard generation == self.generation, !stopped else { return }
        activeProcess = nil
        if phase == .run {
            tunnelClientIsRunning = false
            tunnelRunStartedAt = nil
            hasCompletedControlPlanePoll = false
        }
        guard status == 0 else {
            runtimeKey = nil
            state = .unavailable
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
            state = .unavailable
        }
    }

    func refreshHealth(force: Bool = false) {
        guard !stopped, tunnelClientIsRunning else { return }
        guard activeProcess?.isRunning == true else {
            state = .unavailable
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
            self.state = .unavailable
        }
        Task { [weak self] in
            let isHealthy = await healthProbe(clientPath)
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
                self.state = .unavailable
            }
        }
    }

    nonisolated static func defaultHealthProbe(clientPath: String) async -> Bool {
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
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
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
        exec \(shellQuote(bridgeExecutableURL.path)) --stdio-proxy \(shellQuote(ipcSocketURL.path))
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
