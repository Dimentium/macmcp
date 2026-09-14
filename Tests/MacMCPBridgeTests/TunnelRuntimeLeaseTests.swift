import Foundation
import XCTest
@testable import MacMCPBridge

final class TunnelRuntimeLeaseTests: XCTestCase {
    func testReclaimTerminatesOnlyTheExactLeasedProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leaseStore = TunnelRuntimeLeaseStore(
            fileURL: directory.appendingPathComponent("runtime-lease.json")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try leaseStore.claim(process, executablePath: "/bin/sleep", profile: "macmcp-local")
        await leaseStore.reclaimIfOwned(executablePath: "/usr/bin/false", profile: "macmcp-local")

        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseStore.fileURL.path))
    }

    func testReclaimTerminatesAnExactLeaseAfterAnInterruptedAppExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leaseStore = TunnelRuntimeLeaseStore(
            fileURL: directory.appendingPathComponent("runtime-lease.json")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try leaseStore.claim(process, executablePath: "/bin/sleep", profile: "macmcp-local")
        await leaseStore.reclaimIfOwned(executablePath: "/bin/sleep", profile: "macmcp-local")

        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseStore.fileURL.path))
    }
}
