import Foundation
import MCP
import XCTest
@testable import MacMCPBridge

private enum ProbeBehavior: Sendable {
    case success(String)
    case toolError(String)
    case thrown(String)
    case blocked
}

private struct PrivateProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor FakeEventKitProbeClient {
    private var behaviors: [String: ProbeBehavior]
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var unblocked = false
    private(set) var calls: [String] = []

    init(behaviors: [String: ProbeBehavior]) {
        self.behaviors = behaviors
    }

    func call(publicName: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        calls.append(publicName)
        switch behaviors[publicName] ?? .success("ok") {
        case .success(let text):
            return CallTool.Result(content: [.text(text)])
        case .toolError(let text):
            return CallTool.Result(content: [.text(text)], isError: true)
        case .thrown(let message):
            throw PrivateProbeError(message: message)
        case .blocked:
            await waitUntilUnblocked()
            return CallTool.Result(content: [.text("late private title")])
        }
    }

    func unblock() {
        unblocked = true
        continuation?.resume()
        continuation = nil
    }

    private func waitUntilUnblocked() async {
        guard !unblocked else { return }
        blocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

final class EventKitHealthProberTests: XCTestCase {
    func testSuccessMarksCalendarAndRemindersReady() async {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let client = FakeEventKitProbeClient(behaviors: [
            "calendar.list": .success("Private Calendar"),
            "reminders.list": .success("Private Reminder")
        ])
        let prober = makeProber(source: source, client: client)

        await prober.run()

        let status = await source.snapshot()
        let calls = await client.calls
        XCTAssertEqual(status.calendar, .ready)
        XCTAssertEqual(status.reminders, .ready)
        XCTAssertEqual(calls, ["calendar.list", "reminders.list"])
    }

    func testToolErrorMarksOnlyThatComponentUnavailableAndDoesNotReflectPayload() async {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let client = FakeEventKitProbeClient(behaviors: [
            "calendar.list": .toolError("Private Calendar Name"),
            "reminders.list": .success("Private Reminder")
        ])
        let prober = makeProber(source: source, client: client)

        await prober.run()

        let status = await source.snapshot()
        XCTAssertEqual(status.calendar, .unavailable)
        XCTAssertEqual(status.reminders, .ready)
        let output = await bridgeStatusText(source: source)
        XCTAssertTrue(output.contains("\"calendar\":\"unavailable\""))
        XCTAssertTrue(output.contains("\"reminders\":\"ready\""))
        XCTAssertFalse(output.contains("Private Calendar Name"))
        XCTAssertFalse(output.contains("Private Reminder"))
    }

    func testThrownPrivateErrorMarksOnlyThatComponentUnavailableAndDoesNotReflectMessage() async {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let client = FakeEventKitProbeClient(behaviors: [
            "calendar.list": .success("Private Calendar"),
            "reminders.list": .thrown("Private Reminder Owner")
        ])
        let prober = makeProber(source: source, client: client)

        await prober.run()

        let status = await source.snapshot()
        XCTAssertEqual(status.calendar, .ready)
        XCTAssertEqual(status.reminders, .unavailable)
        let output = await bridgeStatusText(source: source)
        XCTAssertTrue(output.contains("\"calendar\":\"ready\""))
        XCTAssertTrue(output.contains("\"reminders\":\"unavailable\""))
        XCTAssertFalse(output.contains("Private Calendar"))
        XCTAssertFalse(output.contains("Private Reminder Owner"))
    }

    func testTimeoutMarksComponentUnavailableAndStillAttemptsTheOtherProbe() async {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let client = FakeEventKitProbeClient(behaviors: [
            "calendar.list": .blocked,
            "reminders.list": .success("Private Reminder")
        ])
        let prober = makeProber(
            source: source,
            client: client,
            timeoutNanoseconds: 100_000_000,
            onTimeout: { await client.unblock() }
        )
        let started = Date()

        await prober.run()

        let elapsed = Date().timeIntervalSince(started)
        let status = await source.snapshot()
        let calls = await client.calls
        XCTAssertGreaterThanOrEqual(elapsed, 0.08)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(status.calendar, .unavailable)
        XCTAssertEqual(status.reminders, .ready)
        XCTAssertEqual(calls, ["calendar.list", "reminders.list"])
    }

    private func makeProber(
        source: BridgeStatusSource,
        client: FakeEventKitProbeClient,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) -> EventKitHealthProber {
        EventKitHealthProber(
            statusSource: source,
            timeoutNanoseconds: timeoutNanoseconds,
            callTool: { publicName, arguments in
                try await client.call(publicName: publicName, arguments: arguments)
            },
            onTimeout: onTimeout
        )
    }

    private func bridgeStatusText(source: BridgeStatusSource) async -> String {
        let server = await BridgeServer(statusSource: source)
        let result = await server.bridgeStatusResult(arguments: nil)
        guard let first = result.content.first,
              case .text(let text, _, _) = first
        else { return "" }
        return text
    }
}
