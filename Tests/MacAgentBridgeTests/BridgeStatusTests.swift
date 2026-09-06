import XCTest
import MCP
@testable import MacAgentBridge

private actor BridgeToolClient: SidecarToolClient {
    private let advertisedTools: [Tool]

    init(advertisedTools: [Tool]) {
        self.advertisedTools = advertisedTools
    }

    func connect() async throws {}
    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        (advertisedTools, nil)
    }
    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)])
    }
    func disconnect() async {}
}

final class BridgeStatusTests: XCTestCase {
    func testServerRespectsTheExplicitPublishedPolicy() async throws {
        let inputSchema: Value = .object(["type": .string("object")])
        let readerRule = ReaderToolRule(
            publicName: "mail.reader",
            sidecarID: "mail",
            upstreamName: "reader_tool"
        )
        let actionRule = ReaderToolRule(
            publicName: "mail.action",
            sidecarID: "mail",
            upstreamName: "action_tool",
            exposure: .mailAction
        )
        let router = GatewayRouter()
        try await router.attach(
            sidecarID: "mail",
            client: BridgeToolClient(advertisedTools: [
                Tool(name: "reader_tool", description: "", inputSchema: inputSchema),
                Tool(name: "action_tool", description: "", inputSchema: inputSchema)
            ]),
            policy: ReaderPolicy(rules: [readerRule, actionRule])
        )

        let tools = await BridgeServer.exposedTools(
            router: router,
            policy: ReaderPolicy(rules: [readerRule])
        )

        XCTAssertEqual(tools.map(\.name), ["bridge_status", "mail.reader"])
    }

    func testInitialStatusIsReaderOnly() throws {
        let status = BridgeStatus.initial

        XCTAssertEqual(status.mode, .reader)
        XCTAssertFalse(status.writeCapabilitiesEnabled)

        let json = try status.encodedJSON()
        XCTAssertTrue(json.contains("\"mode\":\"reader\""))
        XCTAssertTrue(json.contains("\"writeCapabilitiesEnabled\":false"))
    }

    func testInitialToolSurfaceContainsOnlyStatus() {
        let tools = BridgeServer.defineTools()
        XCTAssertEqual(tools.map(\.name), ["bridge_status"])
        XCTAssertEqual(tools.first?.outputSchema, ReaderOutputSchema.bridgeStatus)
    }

    func testHandshakeAloneLeavesEventKitConnectedUnverified() throws {
        let status = BridgeStatus.connected(mail: true, eventKit: true)

        XCTAssertEqual(status.mail, .connectedUnverified)
        XCTAssertEqual(status.calendar, .connectedUnverified)
        XCTAssertEqual(status.reminders, .connectedUnverified)

        let json = try status.encodedJSON()
        XCTAssertTrue(json.contains("\"calendar\":\"connected_unverified\""))
        XCTAssertTrue(json.contains("\"reminders\":\"connected_unverified\""))
        XCTAssertFalse(json.contains("\"calendar\":\"ready\""))
        XCTAssertFalse(json.contains("\"reminders\":\"ready\""))
    }

    func testCalendarAndRemindersUpdateIndependently() async {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))

        await source.updateCalendar(.ready)
        var status = await source.snapshot()
        XCTAssertEqual(status.calendar, .ready)
        XCTAssertEqual(status.reminders, .connectedUnverified)

        await source.updateReminders(.unavailable)
        status = await source.snapshot()
        XCTAssertEqual(status.calendar, .ready)
        XCTAssertEqual(status.reminders, .unavailable)
    }

    func testMailUpdatesIndependently() async {
        let source = BridgeStatusSource(status: .connected(mail: true, eventKit: false))

        await source.updateMail(.unavailable)
        let status = await source.snapshot()

        XCTAssertEqual(status.mail, .unavailable)
        XCTAssertEqual(status.calendar, .notConfigured)
        XCTAssertEqual(status.reminders, .notConfigured)
    }

    func testWriteCapabilityStatusUpdatesIndependently() async {
        let source = BridgeStatusSource(status: .connected(mail: true, eventKit: false))

        await source.updateWriteCapabilitiesEnabled(true)
        let status = await source.snapshot()

        XCTAssertTrue(status.writeCapabilitiesEnabled)
        XCTAssertEqual(status.mail, .connectedUnverified)
        XCTAssertEqual(status.calendar, .notConfigured)
    }

    func testBridgeStatusReadsUpdatedSnapshot() async throws {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let server = await BridgeServer(statusSource: source)
        var result = await server.bridgeStatusResult(arguments: nil)
        XCTAssertTrue(text(from: result).contains("\"calendar\":\"connected_unverified\""))
        XCTAssertEqual(
            result.structuredContent?.objectValue?["calendar"],
            .string("connected_unverified")
        )

        await source.updateCalendar(.ready)
        result = await server.bridgeStatusResult(arguments: nil)
        XCTAssertTrue(text(from: result).contains("\"calendar\":\"ready\""))
    }

    func testUnavailableStatusIsPrivacySafe() async throws {
        let source = BridgeStatusSource(status: .connected(mail: false, eventKit: true))
        let prober = EventKitHealthProber(
            statusSource: source,
            callTool: { publicName, _ in
                throw NSError(
                    domain: "PrivateHealthProbe",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(publicName) Private Meeting"]
                )
            },
            onTimeout: {}
        )
        await prober.run()
        let server = await BridgeServer(statusSource: source)
        let output = text(from: await server.bridgeStatusResult(arguments: nil))

        XCTAssertTrue(output.contains("\"calendar\":\"unavailable\""))
        XCTAssertTrue(output.contains("\"reminders\":\"unavailable\""))
        XCTAssertFalse(output.contains("Private Meeting"))
        XCTAssertFalse(output.contains("sender@example.com"))
        XCTAssertFalse(output.contains("attendee"))
        XCTAssertFalse(output.contains("Calendar failed"))
    }

    private func text(from result: CallTool.Result) -> String {
        guard let first = result.content.first,
              case .text(let text, _, _) = first
        else { return "" }
        return text
    }
}
