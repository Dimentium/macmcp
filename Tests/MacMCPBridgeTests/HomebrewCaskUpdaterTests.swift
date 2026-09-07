import Foundation
import XCTest
@testable import MacMCPBridge

private actor FakeHomebrewRunner {
    private var results: [HomebrewCommandResult]
    private(set) var commands: [[String]] = []

    init(results: [HomebrewCommandResult]) {
        self.results = results
    }

    func run(arguments: [String], captureOutput: Bool) -> HomebrewCommandResult {
        commands.append(arguments)
        return results.removeFirst()
    }

    func recordedCommands() -> [[String]] {
        commands
    }
}

final class HomebrewCaskUpdaterTests: XCTestCase {
    func testCurrentCaskDoesNotOfferAnUpdate() async {
        let runner = FakeHomebrewRunner(results: [result(text: "macmcp 0.2.7\n")])
        let updater = makeUpdater(runner: runner, latestRelease: "0.2.7")

        let availability = await updater.check()

        XCTAssertEqual(availability, .current)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [["list", "--versions", "--cask", "macmcp"]])
    }

    func testAvailableCaskReportsGitHubReleaseVersionWithoutRefreshingHomebrew() async {
        let runner = FakeHomebrewRunner(results: [result(text: "macmcp 0.2.7\n")])
        let updater = makeUpdater(runner: runner, latestRelease: "0.2.8")

        let availability = await updater.check()

        XCTAssertEqual(availability, .available(version: "0.2.8"))
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [["list", "--versions", "--cask", "macmcp"]])
    }

    func testUnavailableReleaseInformationDisablesUpdates() async {
        let runner = FakeHomebrewRunner(results: [result(text: "macmcp 0.2.7\n")])
        let updater = makeUpdater(runner: runner, latestRelease: nil)

        let availability = await updater.check()

        XCTAssertEqual(availability, .unavailable)
    }

    func testSourceInstallIsNotTreatedAsUpdatableCask() async {
        let runner = FakeHomebrewRunner(results: [result(status: 1)])
        let updater = makeUpdater(runner: runner, latestRelease: "0.2.8")

        let availability = await updater.check()

        XCTAssertEqual(availability, .notCask)
    }

    func testInstallRefreshesThenUpgradesCask() async {
        let runner = FakeHomebrewRunner(results: [
            result(text: "macmcp 0.2.7\n"),
            result(status: 0),
            result(json: #"{"formulae":[],"casks":[{"current_version":"0.2.8"}]}"#),
            result(status: 0)
        ])
        let updater = makeUpdater(runner: runner, latestRelease: "0.2.8")

        let updateResult = await updater.install()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(updateResult, .updated)
        XCTAssertEqual(commands, [
            ["list", "--versions", "--cask", "macmcp"],
            ["update"],
            ["outdated", "--cask", "--json=v2", "macmcp"],
            ["upgrade", "--cask", "macmcp"]
        ])
    }

    func testInstallDoesNotRestartForAReleaseBeforeItsCaskIsPublished() async {
        let runner = FakeHomebrewRunner(results: [
            result(text: "macmcp 0.2.7\n"),
            result(status: 0),
            result(json: #"{"formulae":[],"casks":[]}"#)
        ])
        let updater = makeUpdater(runner: runner, latestRelease: "0.2.8")

        let updateResult = await updater.install()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(updateResult, .current)
        XCTAssertEqual(commands.last, ["outdated", "--cask", "--json=v2", "macmcp"])
    }

    private func makeUpdater(
        runner: FakeHomebrewRunner,
        latestRelease: String?
    ) -> HomebrewCaskUpdater {
        HomebrewCaskUpdater(
            brewPath: "/opt/homebrew/bin/brew",
            commandRunner: { arguments, captureOutput in
                await runner.run(arguments: arguments, captureOutput: captureOutput)
            },
            releaseFetcher: { latestRelease }
        )
    }

    private func result(status: Int32 = 0) -> HomebrewCommandResult {
        HomebrewCommandResult(status: status, standardOutput: Data())
    }

    private func result(text: String) -> HomebrewCommandResult {
        HomebrewCommandResult(status: 0, standardOutput: Data(text.utf8))
    }

    private func result(json: String) -> HomebrewCommandResult {
        HomebrewCommandResult(status: 0, standardOutput: Data(json.utf8))
    }
}
