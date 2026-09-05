import Darwin
import Foundation
import XCTest
@testable import MacAgentBridge

final class BridgeRuntimeTests: XCTestCase {
    func testStartupStopBeforeBindFailsClosedWithoutLaunchingChild() async throws {
        let executable = try makeSleepingExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let startup = BridgeRuntimeStartup()
        await startup.stop()

        let configuration = BridgeLaunchConfiguration(
            mailSidecarURL: nil,
            eventKitSidecarURL: executable,
            iCloudAddress: nil,
            menuBar: true
        )

        let started = Date()
        do {
            _ = try await BridgeRuntime.start(configuration: configuration, startup: startup)
            XCTFail("Expected startup to fail closed after prior stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        let snapshots = await startup.snapshots()
        XCTAssertEqual(snapshots, [])
    }

    func testStartupStopUnblocksHandshakeAndStopsChildProcess() async throws {
        let executable = try makeSleepingExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let startup = BridgeRuntimeStartup()
        let configuration = BridgeLaunchConfiguration(
            mailSidecarURL: nil,
            eventKitSidecarURL: executable,
            iCloudAddress: nil,
            menuBar: true
        )

        let runtimeTask = Task {
            try await BridgeRuntime.start(configuration: configuration, startup: startup)
        }
        let pid = try await waitForRunningPID(startup: startup, sidecarID: ReaderPolicy.eventKitSidecarID)

        runtimeTask.cancel()
        let started = Date()
        await startup.stop()

        do {
            _ = try await EventKitHealthProber.withTimeout(
                nanoseconds: 1_000_000_000,
                onTimeout: {
                    XCTFail("Startup task did not finish after cleanup")
                    await startup.stop()
                },
                operation: {
                    _ = try await runtimeTask.value
                    return true
                }
            )
            XCTFail("Expected startup to fail after cleanup")
        } catch is CancellationError {
        } catch let error as EventKitHealthProbeError where error == .timedOut {
            XCTFail("Startup task timed out instead of unblocking")
        } catch {}

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func makeSleepingExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-agent-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sleeping-sidecar")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func waitForRunningPID(
        startup: BridgeRuntimeStartup,
        sidecarID: String,
        timeout: TimeInterval = 1.0
    ) async throws -> Int32 {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let snapshots = await startup.snapshots()
            if let snapshot = snapshots.first(where: { $0.id == sidecarID }),
               case .running(let pid) = snapshot.state {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for test sidecar to start")
        throw CancellationError()
    }
}
