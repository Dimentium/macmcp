import MCP

#if canImport(System)
import System
#else
import SystemPackage
#endif

protocol SidecarToolClient: Sendable {
    func connect() async throws
    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?)
    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
    func disconnect() async
}

actor SidecarMCPClient: SidecarToolClient {
    private enum ConnectionState {
        case idle
        case connecting
        case connected
    }

    private let client: Client
    private let transport: StdioTransport
    private var state: ConnectionState = .idle

    init(id: String, io: SidecarIO) {
        client = Client(
            name: "\(AppVersion.name)-\(id)",
            version: AppVersion.version,
            configuration: .strict
        )
        transport = StdioTransport(
            input: FileDescriptor(rawValue: io.stdout.fileDescriptor),
            output: FileDescriptor(rawValue: io.stdin.fileDescriptor)
        )
    }

    func connect() async throws {
        guard state == .idle else { return }
        state = .connecting
        do {
            _ = try await client.connect(transport: transport)
            guard state == .connecting else {
                await client.disconnect()
                throw GatewayError.sidecarNotConnected
            }
            state = .connected
        } catch {
            state = .idle
            await client.disconnect()
            throw error
        }
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        guard state == .connected else { throw GatewayError.sidecarNotConnected }
        return try await client.listTools(cursor: cursor)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard state == .connected else { throw GatewayError.sidecarNotConnected }
        let response = try await client.callTool(name: name, arguments: arguments)
        return CallTool.Result(content: response.content, isError: response.isError)
    }

    func disconnect() async {
        guard state != .idle else { return }
        state = .idle
        await client.disconnect()
    }
}
