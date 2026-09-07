import Foundation

struct HomebrewCommandResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: Data
}

enum HomebrewCaskUpdateAvailability: Equatable, Sendable {
    case notCask
    case current
    case available(version: String)
    case unavailable
}

enum HomebrewCaskUpdateResult: Equatable, Sendable {
    case updated
    case current
    case notCask
    case unavailable
}

struct HomebrewCaskUpdater: Sendable {
    typealias CommandRunner = @Sendable (_ arguments: [String], _ captureOutput: Bool) async -> HomebrewCommandResult

    private struct OutdatedResponse: Decodable {
        let casks: [OutdatedCask]
    }

    private struct OutdatedCask: Decodable {
        let currentVersion: String

        enum CodingKeys: String, CodingKey {
            case currentVersion = "current_version"
        }
    }

    private let brewPath: String?
    private let commandRunner: CommandRunner

    init(
        brewPath: String? = HomebrewCaskUpdater.detectBrewPath(),
        commandRunner: CommandRunner? = nil
    ) {
        self.brewPath = brewPath
        if let commandRunner {
            self.commandRunner = commandRunner
        } else if let brewPath {
            self.commandRunner = { arguments, captureOutput in
                await HomebrewCaskUpdater.run(
                    executablePath: brewPath,
                    arguments: arguments,
                    captureOutput: captureOutput
                )
            }
        } else {
            self.commandRunner = { _, _ in HomebrewCommandResult(status: -1, standardOutput: Data()) }
        }
    }

    func check(refreshTap: Bool) async -> HomebrewCaskUpdateAvailability {
        guard brewPath != nil else { return .notCask }
        guard (await commandRunner(["list", "--cask", "macmcp"], false)).status == 0 else {
            return .notCask
        }
        if refreshTap,
           (await commandRunner(["update"], false)).status != 0 {
            return .unavailable
        }

        let result = await commandRunner(
            ["outdated", "--cask", "--json=v2", "macmcp"],
            true
        )
        guard result.status == 0 else { return .unavailable }
        return Self.parseAvailability(result.standardOutput)
    }

    func install() async -> HomebrewCaskUpdateResult {
        switch await check(refreshTap: true) {
        case .notCask:
            return .notCask
        case .current:
            return .current
        case .unavailable:
            return .unavailable
        case .available:
            break
        }

        let result = await commandRunner(["upgrade", "--cask", "macmcp"], false)
        return result.status == 0 ? .updated : .unavailable
    }

    private static func parseAvailability(_ data: Data) -> HomebrewCaskUpdateAvailability {
        guard let response = try? JSONDecoder().decode(OutdatedResponse.self, from: data) else {
            return .unavailable
        }
        guard let cask = response.casks.first else { return .current }
        return cask.currentVersion.isEmpty ? .unavailable : .available(version: cask.currentVersion)
    }

    private static func detectBrewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func run(
        executablePath: String,
        arguments: [String],
        captureOutput: Bool
    ) async -> HomebrewCommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = captureOutput ? Pipe() : nil
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = output ?? FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completed in
                let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: HomebrewCommandResult(
                    status: completed.terminationStatus,
                    standardOutput: data
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: HomebrewCommandResult(status: -1, standardOutput: Data()))
            }
        }
    }
}
