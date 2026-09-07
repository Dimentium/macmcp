import Foundation
import XCTest
@testable import MacMCPBridge

final class SidecarRestartTests: XCTestCase {
    func testUnexpectedExitSchedulesRestart() async throws {
        let recorder = SidecarEventRecorder()
        let supervisor = SidecarSupervisor(eventHandler: { event in
            recorder.record(event)
        })
        let spec = SidecarSpec(
            id: "restart-test",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            restartPolicy: .onUnexpectedExit(maxAttempts: 1, initialDelayMilliseconds: 10)
        )

        _ = try await supervisor.start(spec)

        for _ in 0..<100 {
            if recorder.hasRestart(for: spec.id) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Expected an unexpected sidecar exit to schedule a restart")
    }
}

private final class SidecarEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [SidecarEvent]()

    func record(_ event: SidecarEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func hasRestart(for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return events.contains { event in
            if case .restarting(let eventID, _) = event {
                return eventID == id
            }
            return false
        }
    }
}
