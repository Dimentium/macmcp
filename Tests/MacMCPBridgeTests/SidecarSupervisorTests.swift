import Darwin
import Foundation
import XCTest
@testable import MacMCPBridge

final class SidecarSupervisorTests: XCTestCase {
    func testIdentifierValidation() {
        XCTAssertTrue(SidecarSupervisor.isValidIdentifier("mail.reader-1"))
        XCTAssertFalse(SidecarSupervisor.isValidIdentifier(""))
        XCTAssertFalse(SidecarSupervisor.isValidIdentifier("mail reader"))
        XCTAssertFalse(SidecarSupervisor.isValidIdentifier("../mail"))
    }

    func testBackoffIsBounded() {
        XCTAssertEqual(SidecarSupervisor.backoffMilliseconds(initial: 250, attempt: 1), 250)
        XCTAssertEqual(SidecarSupervisor.backoffMilliseconds(initial: 250, attempt: 3), 1_000)
        XCTAssertEqual(SidecarSupervisor.backoffMilliseconds(initial: 10_000, attempt: 8), 30_000)
    }

    func testMinimalEnvironmentDoesNotForwardAgentSecrets() {
        let environment = SidecarSupervisor.minimalEnvironment(from: [
            "HOME": "/Users/test",
            "PATH": "/custom/bin",
            "OPENAI_API_KEY": "secret",
            "MCP_API_KEY": "secret"
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["PATH"], "/custom/bin")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["MCP_API_KEY"])
    }

    func testStderrSanitizationIsBoundedAndRemovesControls() {
        let input = Data(("ok\u{001B}[31m\u{0000}" + String(repeating: "x", count: 9_000)).utf8)
        let output = SidecarSupervisor.sanitizeStderr(input)

        XCTAssertFalse(output.contains("\u{001B}"))
        XCTAssertFalse(output.contains("\u{0000}"))
        XCTAssertLessThanOrEqual(output.utf8.count, 8_200)
    }

    func testStartsAndStopsDirectExecutable() async throws {
        let supervisor = SidecarSupervisor()
        let spec = SidecarSpec(
            id: "sleep-test",
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            restartPolicy: .never
        )

        _ = try await supervisor.start(spec)
        let running = await supervisor.snapshot(id: spec.id)
        guard case .running = running?.state else {
            return XCTFail("Expected a running sidecar")
        }

        try await supervisor.stop(id: spec.id)
    }

    func testStopAllWaitsForChildProcessExit() async throws {
        let supervisor = SidecarSupervisor()
        let spec = SidecarSpec(
            id: "sleep-stop-all-test",
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            restartPolicy: .never
        )

        _ = try await supervisor.start(spec)
        let running = await supervisor.snapshot(id: spec.id)
        guard case .running(let pid) = running?.state else {
            return XCTFail("Expected a running sidecar")
        }

        await supervisor.stopAll()

        let stopped = await supervisor.snapshot(id: spec.id)
        XCTAssertEqual(stopped?.state, .stopped)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testUnavailableExecutableFailsClosed() async {
        let supervisor = SidecarSupervisor()
        let spec = SidecarSpec(
            id: "missing",
            executableURL: URL(fileURLWithPath: "/definitely/not/present"),
            restartPolicy: .never
        )

        do {
            _ = try await supervisor.start(spec)
            XCTFail("Expected start to fail")
        } catch let error as SidecarSupervisorError {
            XCTAssertEqual(error, .executableUnavailable("/definitely/not/present"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
