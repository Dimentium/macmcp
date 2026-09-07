import Foundation
import MCP
import XCTest
@testable import MacMCPBridge

private actor ScannerSidecarClient: SidecarToolClient {
    private var searchResponses: [String]
    private let readResponse: String
    private(set) var calls: [String] = []

    init(searchResponses: [String], readResponse: String) {
        self.searchResponses = searchResponses
        self.readResponse = readResponse
    }

    func connect() async throws {}

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        let empty = Value.object(["type": .string("object"), "properties": .object([:])])
        let search = Value.object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object(["type": .string("string")]),
                "folder": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")])
            ])
        ])
        let read = Value.object([
            "type": .string("object"),
            "properties": .object([
                "message_id": .object(["type": .string("string")]),
                "max_body_chars": .object(["type": .string("integer")]),
                "mark_as_read": .object(["type": .string("boolean")]),
                "include_html": .object(["type": .string("boolean")]),
                "include_headers": .object(["type": .string("boolean")])
            ])
        ])
        let attachment = Value.object([
            "type": .string("object"),
            "properties": .object([
                "message_id": .object(["type": .string("string")]),
                "part_id": .object(["type": .string("string")]),
                "output_dir": .object(["type": .string("string")])
            ])
        ])
        return ([
            Tool(name: "list_accounts", description: "", inputSchema: empty),
            Tool(name: "get_server_info", description: "", inputSchema: empty),
            Tool(name: "list_folders", description: "", inputSchema: empty),
            Tool(name: "search_emails", description: "", inputSchema: search),
            Tool(name: "read_email", description: "", inputSchema: read),
            Tool(name: "get_attachment", description: "", inputSchema: attachment)
        ], nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        calls.append(name)
        if name == "search_emails" {
            return CallTool.Result(content: [.text(searchResponses.removeFirst())])
        }
        return CallTool.Result(content: [.text(readResponse)])
    }

    func disconnect() async {}
}

private actor ScannerNotificationSink: AttentionNotificationPosting {
    private(set) var items: [AttentionNotification] = []

    func post(_ notification: AttentionNotification) async throws {
        items.append(notification)
    }

    func count() -> Int { items.count }
}

final class MailScannerTests: XCTestCase {
    func testFirstScanBaselinesAndSecondScanNotifiesForOnlyNewUID() async throws {
        let first = #"{"messages":[{"message_id":"aWNsb3Vk.SU5CT1g.42.7"}]}"#
        let second = #"{"messages":[{"message_id":"aWNsb3Vk.SU5CT1g.42.8"},{"message_id":"aWNsb3Vk.SU5CT1g.42.7"}]}"#
        let read = #"{"message":{"from":"Alice <alice@example.com>","subject":"Dinner","body_text":"Are you free?","message_id_header":"<m8@example.com>"}}"#
        let client = ScannerSidecarClient(searchResponses: [first, second], readResponse: read)
        let router = GatewayRouter()
        let policy = ReaderPolicy()
        try await router.attach(sidecarID: ReaderPolicy.mailSidecarID, client: client, policy: policy)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try MonitorStateStore(fileURL: root.appendingPathComponent("state.json"))
        let sink = ScannerNotificationSink()
        let scanner = MailScanner(
            router: router,
            policy: policy,
            state: state,
            notifications: sink
        )

        let baseline = try await scanner.scan()
        let update = try await scanner.scan()

        XCTAssertTrue(baseline.establishedBaseline)
        XCTAssertEqual(baseline.processed, 0)
        XCTAssertEqual(update.processed, 1)
        XCTAssertEqual(update.notified, 1)
        let notificationCount = await sink.count()
        XCTAssertEqual(notificationCount, 1)
    }
}
