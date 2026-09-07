import MCP
import XCTest
@testable import MacMCPBridge

private actor FakeSidecarClient: SidecarToolClient {
    let advertisedTools: [Tool]
    private(set) var calls: [(String, [String: Value]?)] = []
    private(set) var connectCount = 0
    private var connected = false

    init(tools: [Tool]) {
        advertisedTools = tools
    }

    func connect() async throws {
        connectCount += 1
        connected = true
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        if !connected { throw GatewayError.sidecarNotConnected }
        return (advertisedTools, nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        if !connected { throw GatewayError.sidecarNotConnected }
        calls.append((name, arguments))
        return CallTool.Result(content: [.text("ok")])
    }

    func disconnect() async {
        connected = false
    }

    func calledNames() -> [String] {
        calls.map(\.0)
    }
}

private actor HangingConnectClient: SidecarToolClient {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var disconnectCount = 0

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        XCTFail("listTools should not be reached")
        return ([], nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        XCTFail("callTool should not be reached")
        return CallTool.Result(content: [.text("unexpected")])
    }

    func disconnect() async {
        disconnectCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func isWaiting() -> Bool {
        continuation != nil
    }
}

final class GatewayRouterTests: XCTestCase {
    private func tool(_ name: String) -> Tool {
        Tool(
            name: name,
            description: name,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        )
    }

    func testNamespacesDiscoveredTools() async throws {
        let client = FakeSidecarClient(tools: [tool("search_emails"), tool("read_email")])
        let router = GatewayRouter()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            ),
            ReaderToolRule(
                publicName: "mail.read",
                sidecarID: "mail",
                upstreamName: "read_email"
            )
        ])

        try await router.attach(sidecarID: "mail", client: client, policy: policy)

        let names = await router.tools().map(\.name)
        XCTAssertEqual(names, ["mail.read", "mail.search"])
    }

    func testRoutesCallToOriginalToolName() async throws {
        let client = FakeSidecarClient(tools: [tool("search_emails")])
        let router = GatewayRouter()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails",
                allowedArguments: ["account_id"]
            )
        ])
        try await router.attach(sidecarID: "mail", client: client, policy: policy)

        _ = try await router.call(
            publicName: "mail.search",
            arguments: ["account_id": .string("icloud")],
            policy: policy
        )

        let calledNames = await client.calledNames()
        XCTAssertEqual(calledNames, ["search_emails"])
    }

    func testUnknownToolFailsClosed() async {
        let router = GatewayRouter()
        do {
            _ = try await router.call(
                publicName: "mail.delete_email",
                arguments: nil,
                policy: ReaderPolicy()
            )
            XCTFail("Expected unknown tool rejection")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .unknownTool("mail.delete_email"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingPinnedToolFailsClosed() async {
        let router = GatewayRouter()
        let client = FakeSidecarClient(tools: [])
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])
        do {
            try await router.attach(sidecarID: "mail", client: client, policy: policy)
            XCTFail("Expected missing tool rejection")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .missingUpstreamTool("search_emails"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDuplicateUpstreamToolFailsClosedWithoutTrap() async {
        let router = GatewayRouter()
        let client = FakeSidecarClient(tools: [tool("search_emails"), tool("search_emails")])
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])

        do {
            try await router.attach(sidecarID: "mail", client: client, policy: policy)
            XCTFail("Expected duplicate upstream tool rejection")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .duplicateUpstreamTool("search_emails"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledAttachDoesNotConnectClient() async throws {
        let router = GatewayRouter()
        let client = FakeSidecarClient(tools: [tool("search_emails")])
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])

        let attachTask = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await router.attach(sidecarID: "mail", client: client, policy: policy)
        }

        do {
            try await attachTask.value
            XCTFail("Expected cancelled attach to fail")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let connectCount = await client.connectCount
        let toolNames = await router.tools().map(\.name)
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(toolNames, [])
    }

    func testDetachDisconnectsClientDuringAttachHandshake() async throws {
        let router = GatewayRouter()
        let client = HangingConnectClient()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "eventkit.test",
                sidecarID: "eventkit",
                upstreamName: "test"
            )
        ])

        let attachTask = Task {
            try await router.attach(sidecarID: "eventkit", client: client, policy: policy)
        }
        for _ in 0..<100 {
            if await client.isWaiting() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let isWaiting = await client.isWaiting()
        XCTAssertTrue(isWaiting)

        await router.detach(sidecarID: "eventkit")

        do {
            try await attachTask.value
            XCTFail("Expected attach to fail after detach")
        } catch is CancellationError {
        }
        let disconnectCount = await client.disconnectCount
        let toolNames = await router.tools().map(\.name)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(toolNames, [])
    }
}
