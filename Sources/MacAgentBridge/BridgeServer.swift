import Foundation
import MCP

final class BridgeServer {
    private let server: Server
    private let transport: StdioTransport
    private let tools: [Tool]
    private let router: GatewayRouter?
    private let policy: ReaderPolicy
    private let statusSource: BridgeStatusSource
    private let attachmentReader: AttachmentTextReader?

    init(
        router: GatewayRouter? = nil,
        policy: ReaderPolicy = ReaderPolicy(),
        statusSource: BridgeStatusSource = BridgeStatusSource(),
        attachmentReader: AttachmentTextReader? = nil
    ) async {
        self.router = router
        self.policy = policy
        self.statusSource = statusSource
        self.attachmentReader = attachmentReader
        var exposed = Self.defineTools()
        if let router {
            exposed.append(contentsOf: await router.tools())
        }
        tools = exposed.sorted { $0.name < $1.name }
        server = Server(
            name: AppVersion.name,
            version: AppVersion.version,
            capabilities: .init(tools: .init())
        )
        transport = StdioTransport()
        await registerHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    static func defineTools() -> [Tool] {
        [
            Tool(
                name: "bridge_status",
                description: "Report local bridge health and capability mode. Does not access personal data.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false),
                outputSchema: ReaderOutputSchema.bridgeStatus
            )
        ]
    }

    func bridgeStatusResult(arguments: [String: Value]?) async -> CallTool.Result {
        guard arguments?.isEmpty ?? true else {
            return CallTool.Result(
                content: [.text("bridge_status accepts no arguments")],
                isError: true
            )
        }

        do {
            let status = await statusSource.snapshot()
            let structuredContent: Value? = try Value(status)
            return CallTool.Result(
                content: [.text(try status.encodedJSON())],
                structuredContent: structuredContent
            )
        } catch {
            return CallTool.Result(content: [.text("Unable to encode status")], isError: true)
        }
    }

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [router, policy, attachmentReader, weak self] params in
            if params.name == "bridge_status" {
                return await self?.bridgeStatusResult(arguments: params.arguments) ?? CallTool.Result(
                    content: [.text("Unable to encode status")],
                    isError: true
                )
            }

            if params.name == AttachmentTextReader.publicToolName {
                guard let attachmentReader else {
                    return CallTool.Result(
                        content: [.text("Unknown or unavailable tool")],
                        isError: true
                    )
                }
                return await attachmentReader.read(arguments: params.arguments)
            }

            guard let router else {
                return CallTool.Result(
                    content: [.text("Unknown or unavailable tool")],
                    isError: true
                )
            }

            do {
                return try await router.call(
                    publicName: params.name,
                    arguments: params.arguments,
                    policy: policy
                )
            } catch {
                // Sidecar error strings may contain attacker-controlled mailbox
                // content. Keep the public failure stable and non-reflective.
                return CallTool.Result(
                    content: [.text("Reader request was rejected or failed")],
                    isError: true
                )
            }
        }
    }
}
