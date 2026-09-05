import Darwin
import Foundation

enum SidecarRestartPolicy: Equatable, Sendable {
    case never
    case onUnexpectedExit(maxAttempts: Int, initialDelayMilliseconds: UInt64)
}

struct SidecarSpec: Equatable, Sendable {
    let id: String
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let restartPolicy: SidecarRestartPolicy

    init(
        id: String,
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        restartPolicy: SidecarRestartPolicy = .onUnexpectedExit(
            maxAttempts: 5,
            initialDelayMilliseconds: 250
        )
    ) {
        self.id = id
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.restartPolicy = restartPolicy
    }
}

enum SidecarState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    case restarting(attempt: Int)
    case failed(reason: String)
}

struct SidecarSnapshot: Equatable, Sendable {
    let id: String
    let state: SidecarState
    let restartCount: Int
}

struct SidecarIO: @unchecked Sendable {
    let stdin: FileHandle
    let stdout: FileHandle
}

enum SidecarEvent: Equatable, Sendable {
    case started(id: String, pid: Int32)
    case stopped(id: String, status: Int32)
    case restarting(id: String, attempt: Int)
    case stderr(id: String, text: String)
    case failed(id: String, reason: String)
}

enum SidecarSupervisorError: LocalizedError, Equatable {
    case invalidIdentifier
    case duplicateIdentifier(String)
    case executableUnavailable(String)
    case notRunning(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "Sidecar identifier must contain only letters, digits, dots, dashes, or underscores"
        case .duplicateIdentifier(let id):
            return "Sidecar \(id) is already registered"
        case .executableUnavailable(let path):
            return "Sidecar executable is unavailable: \(path)"
        case .notRunning(let id):
            return "Sidecar \(id) is not running"
        }
    }
}

actor SidecarSupervisor {
    typealias EventHandler = @Sendable (SidecarEvent) -> Void

    private final class ManagedSidecar {
        let spec: SidecarSpec
        var process: Process?
        var inputPipe: Pipe?
        var outputPipe: Pipe?
        var errorPipe: Pipe?
        var state: SidecarState = .stopped
        var desiredRunning = false
        var restartCount = 0
        var generation = 0

        init(spec: SidecarSpec) {
            self.spec = spec
        }
    }

    private var sidecars: [String: ManagedSidecar] = [:]
    private let eventHandler: EventHandler

    init(eventHandler: @escaping EventHandler = { _ in }) {
        self.eventHandler = eventHandler
    }

    func start(_ spec: SidecarSpec) throws -> SidecarIO {
        try Task.checkCancellation()
        guard Self.isValidIdentifier(spec.id) else {
            throw SidecarSupervisorError.invalidIdentifier
        }
        guard sidecars[spec.id] == nil else {
            throw SidecarSupervisorError.duplicateIdentifier(spec.id)
        }
        guard FileManager.default.isExecutableFile(atPath: spec.executableURL.path) else {
            throw SidecarSupervisorError.executableUnavailable(spec.executableURL.path)
        }

        let managed = ManagedSidecar(spec: spec)
        managed.desiredRunning = true
        sidecars[spec.id] = managed

        do {
            try Task.checkCancellation()
            return try launch(managed)
        } catch {
            managed.state = .failed(reason: "launch_failed")
            managed.desiredRunning = false
            eventHandler(.failed(id: spec.id, reason: "launch_failed"))
            throw error
        }
    }

    func stop(id: String) async throws {
        guard let managed = sidecars[id] else {
            throw SidecarSupervisorError.notRunning(id)
        }

        await stop(managed)
    }

    func stopAll() async {
        for managed in sidecars.values {
            await stop(managed)
        }
    }

    func connection(for id: String) throws -> SidecarIO {
        guard
            let managed = sidecars[id],
            case .running = managed.state,
            let inputPipe = managed.inputPipe,
            let outputPipe = managed.outputPipe
        else {
            throw SidecarSupervisorError.notRunning(id)
        }

        return SidecarIO(
            stdin: inputPipe.fileHandleForWriting,
            stdout: outputPipe.fileHandleForReading
        )
    }

    func snapshot(id: String) -> SidecarSnapshot? {
        guard let managed = sidecars[id] else { return nil }
        return SidecarSnapshot(
            id: id,
            state: managed.state,
            restartCount: managed.restartCount
        )
    }

    func snapshots() -> [SidecarSnapshot] {
        sidecars.values
            .map {
                SidecarSnapshot(
                    id: $0.spec.id,
                    state: $0.state,
                    restartCount: $0.restartCount
                )
            }
            .sorted { $0.id < $1.id }
    }

    private func launch(_ managed: ManagedSidecar) throws -> SidecarIO {
        managed.generation += 1
        let generation = managed.generation
        managed.state = .starting

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = managed.spec.executableURL
        process.arguments = managed.spec.arguments
        process.environment = Self.minimalEnvironment(
            from: ProcessInfo.processInfo.environment
        ).merging(
            managed.spec.environment,
            uniquingKeysWith: { _, sidecarValue in sidecarValue }
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let id = managed.spec.id
        let eventHandler = self.eventHandler
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = Self.sanitizeStderr(data)
            guard !text.isEmpty else { return }
            eventHandler(.stderr(id: id, text: text))
        }

        process.terminationHandler = { [weak self] process in
            Task {
                await self?.processDidTerminate(
                    id: id,
                    generation: generation,
                    status: process.terminationStatus
                )
            }
        }

        try process.run()

        managed.process = process
        managed.inputPipe = inputPipe
        managed.outputPipe = outputPipe
        managed.errorPipe = errorPipe
        managed.state = .running(pid: process.processIdentifier)
        eventHandler(.started(id: id, pid: process.processIdentifier))

        return SidecarIO(
            stdin: inputPipe.fileHandleForWriting,
            stdout: outputPipe.fileHandleForReading
        )
    }

    private func processDidTerminate(id: String, generation: Int, status: Int32) async {
        guard let managed = sidecars[id], managed.generation == generation else {
            return
        }

        cleanupTerminatedProcess(managed)
        eventHandler(.stopped(id: id, status: status))

        guard managed.desiredRunning else {
            managed.state = .stopped
            return
        }

        guard case let .onUnexpectedExit(maxAttempts, initialDelayMilliseconds) = managed.spec.restartPolicy,
              managed.restartCount < max(0, maxAttempts)
        else {
            managed.state = .failed(reason: "restart_limit_reached")
            eventHandler(.failed(id: id, reason: "restart_limit_reached"))
            return
        }

        managed.restartCount += 1
        let attempt = managed.restartCount
        managed.state = .restarting(attempt: attempt)
        eventHandler(.restarting(id: id, attempt: attempt))

        let delay = Self.backoffMilliseconds(
            initial: initialDelayMilliseconds,
            attempt: attempt
        )
        try? await Task.sleep(nanoseconds: delay * 1_000_000)

        guard managed.desiredRunning, managed.generation == generation else {
            return
        }

        do {
            _ = try launch(managed)
        } catch {
            managed.state = .failed(reason: "restart_launch_failed")
            eventHandler(.failed(id: id, reason: "restart_launch_failed"))
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func minimalEnvironment(from source: [String: String]) -> [String: String] {
        let allowed = ["HOME", "USER", "TMPDIR", "LANG", "LC_ALL", "PATH"]
        var result: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        for key in allowed where source[key] != nil {
            result[key] = source[key]
        }
        return result
    }

    static func backoffMilliseconds(initial: UInt64, attempt: Int) -> UInt64 {
        let boundedAttempt = min(max(attempt, 1), 8)
        let multiplier = UInt64(1 << (boundedAttempt - 1))
        let multiplied = initial.multipliedReportingOverflow(by: multiplier)
        return multiplied.overflow ? 30_000 : min(multiplied.partialValue, 30_000)
    }

    static func sanitizeStderr(_ data: Data) -> String {
        let bounded = data.prefix(8_192)
        let decoded = String(decoding: bounded, as: UTF8.self)
        let scalars = decoded.unicodeScalars.map { scalar -> Character in
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                return Character(String(scalar))
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return "�"
            }
            return Character(String(scalar))
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stop(_ managed: ManagedSidecar) async {
        managed.desiredRunning = false
        managed.state = .stopping
        managed.errorPipe?.fileHandleForReading.readabilityHandler = nil

        guard let process = managed.process else {
            cleanupTerminatedProcess(managed)
            managed.state = .stopped
            return
        }

        if process.isRunning {
            process.terminate()
            await waitForExit(process, timeoutNanoseconds: 2_000_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            await waitForExit(process, timeoutNanoseconds: 2_000_000_000)
        }

        cleanupTerminatedProcess(managed)
        managed.state = .stopped
    }

    private func waitForExit(_ process: Process, timeoutNanoseconds: UInt64) async {
        let interval: UInt64 = 50_000_000
        var elapsed: UInt64 = 0
        while process.isRunning && elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
    }

    private func cleanupTerminatedProcess(_ managed: ManagedSidecar) {
        managed.errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? managed.inputPipe?.fileHandleForWriting.close()
        try? managed.outputPipe?.fileHandleForReading.close()
        try? managed.errorPipe?.fileHandleForReading.close()
        managed.process = nil
        managed.inputPipe = nil
        managed.outputPipe = nil
        managed.errorPipe = nil
    }
}
