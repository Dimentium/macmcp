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
    typealias ReleaseFetcher = @Sendable () async -> String?

    private struct LatestReleaseResponse: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private struct OutdatedResponse: Decodable {
        let casks: [OutdatedCask]
    }

    private struct OutdatedCask: Decodable {
        let currentVersion: String

        enum CodingKeys: String, CodingKey {
            case currentVersion = "current_version"
        }
    }

    private struct SemanticVersion: Comparable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ value: String) {
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  let major = Int(components[0]),
                  let minor = Int(components[1]),
                  let patch = Int(components[2]),
                  major >= 0,
                  minor >= 0,
                  patch >= 0
            else {
                return nil
            }
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    private let brewPath: String?
    private let commandRunner: CommandRunner
    private let releaseFetcher: ReleaseFetcher

    init(
        brewPath: String? = HomebrewCaskUpdater.detectBrewPath(),
        commandRunner: CommandRunner? = nil,
        releaseFetcher: ReleaseFetcher? = nil
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
        self.releaseFetcher = releaseFetcher ?? {
            await HomebrewCaskUpdater.fetchLatestReleaseVersion()
        }
    }

    func check() async -> HomebrewCaskUpdateAvailability {
        guard brewPath != nil else { return .notCask }
        let installed = await commandRunner(["list", "--versions", "--cask", "macmcp"], true)
        guard installed.status == 0,
              let installedVersion = Self.parseInstalledVersion(installed.standardOutput)
        else {
            return .notCask
        }
        guard let latestVersion = await releaseFetcher(),
              let latest = SemanticVersion(latestVersion)
        else {
            return .unavailable
        }
        return latest > installedVersion ? .available(version: latestVersion) : .current
    }

    func install() async -> HomebrewCaskUpdateResult {
        switch await check() {
        case .notCask:
            return .notCask
        case .current:
            return .current
        case .unavailable:
            return .unavailable
        case .available:
            break
        }

        guard (await commandRunner(["update"], false)).status == 0 else {
            return .unavailable
        }
        let outdated = await commandRunner(
            ["outdated", "--cask", "--json=v2", "macmcp"],
            true
        )
        guard outdated.status == 0 else { return .unavailable }
        switch Self.parseOutdatedAvailability(outdated.standardOutput) {
        case .available:
            break
        case .current:
            return .current
        case .notCask, .unavailable:
            return .unavailable
        }

        let result = await commandRunner(["upgrade", "--cask", "macmcp"], false)
        return result.status == 0 ? .updated : .unavailable
    }

    private static func parseInstalledVersion(_ data: Data) -> SemanticVersion? {
        let fields = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
        guard fields.first == "macmcp",
              let version = fields.dropFirst().first
        else {
            return nil
        }
        return SemanticVersion(String(version))
    }

    private static func parseOutdatedAvailability(_ data: Data) -> HomebrewCaskUpdateAvailability {
        guard let response = try? JSONDecoder().decode(OutdatedResponse.self, from: data) else {
            return .unavailable
        }
        guard let cask = response.casks.first,
              SemanticVersion(cask.currentVersion) != nil
        else {
            return .current
        }
        return .available(version: cask.currentVersion)
    }

    private static func fetchLatestReleaseVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/Dimentium/macmcp/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MacMCP update checker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let version = try? JSONDecoder().decode(LatestReleaseResponse.self, from: data).tagName,
                  version.hasPrefix("v")
            else {
                return nil
            }
            let normalized = String(version.dropFirst())
            return SemanticVersion(normalized) == nil ? nil : normalized
        } catch {
            return nil
        }
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
