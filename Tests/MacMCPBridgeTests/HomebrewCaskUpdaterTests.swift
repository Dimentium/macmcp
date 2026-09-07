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
        let runner = FakeHomebrewRunner(results: [
            result(status: 0),
            result(json: #"{"formulae":[],"casks":[]}"#)
        ])
        let updater = HomebrewCaskUpdater(
            brewPath: "/opt/homebrew/bin/brew",
            commandRunner: { arguments, captureOutput in
                await runner.run(arguments: arguments, captureOutput: captureOutput)
            }
        )

        let availability = await updater.check(refreshTap: false)

        XCTAssertEqual(availability, .current)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [
            ["list", "--cask", "macmcp"],
            ["outdated", "--cask", "--json=v2", "macmcp"]
        ])
    }

    func testAvailableCaskReportsTargetVersion() async {
        let runner = FakeHomebrewRunner(results: [
            result(status: 0),
            result(status: 0),
            result(json: #"{"formulae":[],"casks":[{"current_version":"0.2.7"}]}"#)
        ])
        let updater = HomebrewCaskUpdater(
            brewPath: "/opt/homebrew/bin/brew",
            commandRunner: { arguments, captureOutput in
                await runner.run(arguments: arguments, captureOutput: captureOutput)
            }
        )

        let availability = await updater.check(refreshTap: true)

        XCTAssertEqual(availability, .available(version: "0.2.7"))
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [
            ["list", "--cask", "macmcp"],
            ["update"],
            ["outdated", "--cask", "--json=v2", "macmcp"]
        ])
    }

    func testSourceInstallIsNotTreatedAsUpdatableCask() async {
        let runner = FakeHomebrewRunner(results: [result(status: 1)])
        let updater = HomebrewCaskUpdater(
            brewPath: "/opt/homebrew/bin/brew",
            commandRunner: { arguments, captureOutput in
                await runner.run(arguments: arguments, captureOutput: captureOutput)
            }
        )

        let availability = await updater.check(refreshTap: false)
        XCTAssertEqual(availability, .notCask)
    }

    func testInstallRefreshesThenUpgradesCask() async {
        let runner = FakeHomebrewRunner(results: [
            result(status: 0),
            result(status: 0),
            result(json: #"{"formulae":[],"casks":[{"current_version":"0.2.7"}]}"#),
            result(status: 0)
        ])
        let updater = HomebrewCaskUpdater(
            brewPath: "/opt/homebrew/bin/brew",
            commandRunner: { arguments, captureOutput in
                await runner.run(arguments: arguments, captureOutput: captureOutput)
            }
        )

        let updateResult = await updater.install()
        let commands = await runner.recordedCommands()
        XCTAssertEqual(updateResult, .updated)
        XCTAssertEqual(commands.last, ["upgrade", "--cask", "macmcp"])
    }

    private func result(status: Int32 = 0) -> HomebrewCommandResult {
        HomebrewCommandResult(status: status, standardOutput: Data())
    }

    private func result(json: String) -> HomebrewCommandResult {
        HomebrewCommandResult(status: 0, standardOutput: Data(json.utf8))
    }
}
