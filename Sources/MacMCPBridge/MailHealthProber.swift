import Foundation
import MCP

struct MailHealthProber: Sendable {
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

    @discardableResult
    func probe() async -> Bool {
        do {
            let ok = try await EventKitHealthProber.withTimeout(
                nanoseconds: timeoutNanoseconds,
                onTimeout: onTimeout,
                operation: {
                    let result = try await callTool("mail.server_info", nil)
                    return result.isError != true
                }
            )
            await statusSource.updateMail(ok ? .ready : .unavailable)
            return ok
        } catch {
            await statusSource.updateMail(.unavailable)
            return false
        }
    }
}
