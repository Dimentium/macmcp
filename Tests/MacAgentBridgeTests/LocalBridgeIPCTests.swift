import Darwin
import Foundation
import MCP
import XCTest
@testable import MacAgentBridge

private actor IPCFakeSidecarClient: SidecarToolClient {
    private(set) var calls: [String] = []
    private var connected = false

    func connect() async throws {
        connected = true
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        if !connected { throw GatewayError.sidecarNotConnected }
        return ([
            Tool(
                name: "search_emails",
                description: "search",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            )
        ], nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        if !connected { throw GatewayError.sidecarNotConnected }
        calls.append(name)
        return CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)])
    }

    func disconnect() async {
        connected = false
    }
}

private actor IPCSlowSidecarClient: SidecarToolClient {
    private var connected = false

    func connect() async throws {
        connected = true
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        if !connected { throw GatewayError.sidecarNotConnected }
        return ([
            Tool(
                name: "search_emails",
                description: "search",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            )
        ], nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)])
    }

    func disconnect() async {
        connected = false
    }
}

final class LocalBridgeIPCTests: XCTestCase {
    func testIPCServerHandlesInitializeToolsAndStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools(),
            router: GatewayRouter(),
            policy: ReaderPolicy(),
            statusSource: BridgeStatusSource()
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }

        let initialize = try request(
            fd: fd,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "test", "version": "0"]
            ]
        )
        XCTAssertNil(initialize["error"])
        XCTAssertNotNil((initialize["result"] as? [String: Any])?["serverInfo"])

        let listTools = try request(fd: fd, id: 2, method: "tools/list", params: [:])
        let tools = ((listTools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["bridge_status"])
        let outputSchema = tools.first?["outputSchema"] as? [String: Any]
        XCTAssertEqual(outputSchema?["type"] as? String, "object")
        XCTAssertNotNil((outputSchema?["properties"] as? [String: Any])?["version"])

        let status = try request(
            fd: fd,
            id: 3,
            method: "tools/call",
            params: ["name": "bridge_status", "arguments": [:]]
        )
        let content = ((status["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertTrue((content.first?["text"] as? String)?.contains("\"writeCapabilitiesEnabled\":false") == true)
        let structuredContent = (status["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(structuredContent?["mode"] as? String, "reader")
        XCTAssertEqual(structuredContent?["writeCapabilitiesEnabled"] as? Bool, false)

        let namespacedStatus = try request(
            fd: fd,
            id: 4,
            method: "tools/call",
            params: ["name": "macMCP.bridge_status", "arguments": [:]]
        )
        XCTAssertNil(namespacedStatus["error"])
    }

    func testDefaultSocketURLUsesApplicationSupport() {
        let path = LocalBridgeIPC.defaultSocketURL().path

        XCTAssertTrue(path.contains("Library/Application Support/mac-agent-bridge"))
        XCTAssertTrue(path.hasSuffix("/mcp.sock"))
    }

    func testBridgeStatusClientReadsStatusFromIPCServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let status = BridgeStatus(
            version: AppVersion.version,
            mode: .reader,
            mail: .ready,
            calendar: .unavailable,
            reminders: .connectedUnverified,
            mailRestartCount: 2,
            eventKitRestartCount: 1,
            writeCapabilitiesEnabled: false
        )
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools(),
            router: GatewayRouter(),
            policy: ReaderPolicy(),
            statusSource: BridgeStatusSource(status: status)
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let json = try LocalBridgeIPC.requestBridgeStatus(socketPath: socketURL.path)

        XCTAssertEqual(json, try status.encodedJSON())
    }

    func testIdleClientsDoNotBlockStatusRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools(),
            router: GatewayRouter(),
            policy: ReaderPolicy(),
            statusSource: BridgeStatusSource()
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let idleClients = try (0..<32).map { _ in try connect(to: socketURL.path) }
        defer { idleClients.forEach { close($0) } }

        let json = try LocalBridgeIPC.requestBridgeStatus(socketPath: socketURL.path)

        XCTAssertTrue(json.contains("\"writeCapabilitiesEnabled\":false"))
    }

    func testOversizedFrameClosesClientConnection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools(),
            router: GatewayRouter(),
            policy: ReaderPolicy(),
            statusSource: BridgeStatusSource(),
            limits: LocalBridgeIPCLimits(maximumFrameBytes: 32)
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        try writeAll(Data(repeating: UInt8(ascii: "x"), count: 33), to: fd)

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0)
    }

    func testTimedOutRequestReturnsStructuredIPCError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let approvalURL = directory.appendingPathComponent("approved-clients.json")
        let identity = LocalClientIdentity(
            uid: 501,
            pid: 123,
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            executableSHA256: "abc123"
        )
        let approvalStore = ClientApprovalStore(fileURL: approvalURL, expectedUID: 501)
        let router = GatewayRouter()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])
        try await router.attach(sidecarID: "mail", client: IPCSlowSidecarClient(), policy: policy)
        _ = try await approvalStore.authorize(identity)
        _ = try await approvalStore.approvePending()
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools() + (await router.tools()),
            router: router,
            policy: policy,
            statusSource: BridgeStatusSource(),
            clientApprovalStore: approvalStore,
            identityProvider: { _ in identity },
            limits: LocalBridgeIPCLimits(requestTimeout: 0.01)
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        let response = try request(
            fd: fd,
            id: 1,
            method: "tools/call",
            params: ["name": "mail.search", "arguments": [:]]
        )

        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32003)
    }

    func testDataToolsRequireApprovedClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let approvalURL = directory.appendingPathComponent("approved-clients.json")
        let identity = LocalClientIdentity(
            uid: 501,
            pid: 123,
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            executableSHA256: "abc123"
        )
        let approvalStore = ClientApprovalStore(fileURL: approvalURL, expectedUID: 501)
        let router = GatewayRouter()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])
        let sidecar = IPCFakeSidecarClient()
        try await router.attach(sidecarID: "mail", client: sidecar, policy: policy)
        let tools = BridgeServer.defineTools() + (await router.tools())
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: tools,
            router: router,
            policy: policy,
            statusSource: BridgeStatusSource(),
            clientApprovalStore: approvalStore,
            identityProvider: { _ in identity }
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let deniedFD = try connect(to: socketURL.path)
        defer { close(deniedFD) }
        let denied = try request(
            fd: deniedFD,
            id: 1,
            method: "tools/call",
            params: ["name": "mail.search", "arguments": [:]]
        )
        let error = denied["error"] as? [String: Any]
        let deniedCalls = await sidecar.calls
        XCTAssertEqual(denied["id"] as? Int, 1)
        XCTAssertEqual(error?["code"] as? Int, -32001)
        XCTAssertEqual(deniedCalls, [])

        _ = try await approvalStore.approvePending()

        let approvedFD = try connect(to: socketURL.path)
        defer { close(approvedFD) }
        let approved = try request(
            fd: approvedFD,
            id: 2,
            method: "tools/call",
            params: ["name": "macMCP.mail.search", "arguments": [:]]
        )
        let approvedCalls = await sidecar.calls
        XCTAssertNil(approved["error"])
        XCTAssertEqual(approvedCalls, ["search_emails"])
    }

    func testUnpublishedToolCannotBeCalledEvenWhenRouterKnowsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let router = GatewayRouter()
        let policy = ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: "mail.search",
                sidecarID: "mail",
                upstreamName: "search_emails"
            )
        ])
        let sidecar = IPCFakeSidecarClient()
        try await router.attach(sidecarID: "mail", client: sidecar, policy: policy)
        let server = LocalBridgeIPCServer(
            socketURL: socketURL,
            tools: BridgeServer.defineTools(),
            router: router,
            policy: policy,
            statusSource: BridgeStatusSource()
        )
        try server.start()
        defer {
            Task { await server.stop() }
        }

        let fd = try connect(to: socketURL.path)
        defer { close(fd) }
        let response = try request(
            fd: fd,
            id: 1,
            method: "tools/call",
            params: ["name": "mail.search", "arguments": [:]]
        )

        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        let calls = await sidecar.calls
        XCTAssertEqual(calls, [])
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        try UnixSocketAddress.withSockAddr(path: path) { address, length in
            XCTAssertEqual(Darwin.connect(fd, address, length), 0)
        }
        return fd
    }

    private func request(
        fd: Int32,
        id: Int,
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([UInt8(ascii: "\n")])
        try writeAll(data, to: fd)
        return try readJSONLine(from: fd)
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                base += written
                remaining -= written
            }
        }
    }

    private func readJSONLine(from fd: Int32) throws -> [String: Any] {
        var line = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let count = read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                throw POSIXError(.ENOTCONN)
            }
            if byte[0] == UInt8(ascii: "\n") {
                break
            }
            line.append(byte[0])
        }
        let object = try JSONSerialization.jsonObject(with: line)
        return try XCTUnwrap(object as? [String: Any])
    }
}
