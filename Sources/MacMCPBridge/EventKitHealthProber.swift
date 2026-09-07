import Foundation
import MCP

enum EventKitHealthProbeError: Error, Equatable {
    case timedOut
}

private actor EventKitHealthTimeoutState {
    private var timedOut = false

    func markTimedOut() {
        timedOut = true
    }

    func hasTimedOut() -> Bool {
        timedOut
    }
}

enum EventKitHealthComponent: CaseIterable, Sendable {
    case calendar
    case reminders

    var publicToolName: String {
        switch self {
        case .calendar:
            return "calendar.list"
        case .reminders:
            return "reminders.list"
        }
    }

    var arguments: [String: Value]? {
        switch self {
        case .calendar:
            return nil
        case .reminders:
            return ["limit": .int(1)]
        }
    }
}

struct EventKitHealthProber: Sendable {
    typealias ToolCall = @Sendable (_ publicName: String, _ arguments: [String: Value]?) async throws -> CallTool.Result

    let statusSource: BridgeStatusSource
    let timeoutNanoseconds: UInt64
    let callTool: ToolCall
    let onTimeout: @Sendable () async -> Void

    init(
        statusSource: BridgeStatusSource,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        callTool: @escaping ToolCall,
        onTimeout: @escaping @Sendable () async -> Void
    ) {
        self.statusSource = statusSource
        self.timeoutNanoseconds = timeoutNanoseconds
        self.callTool = callTool
        self.onTimeout = onTimeout
    }

    func run() async {
        for component in EventKitHealthComponent.allCases {
            await probe(component)
        }
    }

    @discardableResult
    func probe(_ component: EventKitHealthComponent) async -> Bool {
        do {
            let ok = try await Self.withTimeout(
                nanoseconds: timeoutNanoseconds,
                onTimeout: onTimeout,
                operation: {
                    let result = try await callTool(component.publicToolName, component.arguments)
                    return result.isError != true
                }
            )
            await update(component, state: ok ? .ready : .unavailable)
            return ok
        } catch {
            await update(component, state: .unavailable)
            return false
        }
    }

    static func withTimeout<T: Sendable>(
        nanoseconds: UInt64,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = EventKitHealthTimeoutState()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                do {
                    let value = try await operation()
                    if await state.hasTimedOut() {
                        throw EventKitHealthProbeError.timedOut
                    }
                    return value
                } catch {
                    if await state.hasTimedOut() {
                        throw EventKitHealthProbeError.timedOut
                    }
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                await state.markTimedOut()
                await onTimeout()
                throw EventKitHealthProbeError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw EventKitHealthProbeError.timedOut
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func update(_ component: EventKitHealthComponent, state: BridgeStatus.ComponentState) async {
        switch component {
        case .calendar:
            await statusSource.updateCalendar(state)
        case .reminders:
            await statusSource.updateReminders(state)
        }
    }
}
