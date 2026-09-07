import Foundation
import MCP
import XCTest
@testable import MacMCPBridge

private actor AttachmentSidecarClient: SidecarToolClient {
    private let response: String
    private(set) var calls: [(String, [String: Value]?)] = []
    private var connected = false

    init(response: String) {
        self.response = response
    }

    func connect() async throws {
        connected = true
    }

    func listTools(cursor: String?) async throws -> (tools: [Tool], nextCursor: String?) {
        guard connected else { throw GatewayError.sidecarNotConnected }
        return ([
            Tool(
                name: "get_attachment",
                description: "download",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "message_id": .object(["type": .string("string")]),
                        "part_id": .object(["type": .string("string")]),
                        "output_dir": .object(["type": .string("string")])
                    ])
                ])
            )
        ], nil)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard connected else { throw GatewayError.sidecarNotConnected }
        calls.append((name, arguments))
        return CallTool.Result(content: [.text(response)])
    }

    func disconnect() async {
        connected = false
    }

    func recordedCalls() -> [(String, [String: Value]?)] {
        calls
    }
}

final class AttachmentTextReaderTests: XCTestCase {
    func testExtractsTextAndRemovesTemporaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AttachmentStorage(directoryURL: root.appendingPathComponent("attachments"))
        try storage.prepare()
        let fileURL = storage.directoryURL.appendingPathComponent("report.txt")
        try Data("Approved content only".utf8).write(to: fileURL)

        let response = try downloadResponse(
            fileURL: fileURL,
            filename: "report.txt",
            contentType: "text/plain"
        )
        let client = AttachmentSidecarClient(response: response)
        let router = GatewayRouter()
        let policy = attachmentPolicy()
        try await router.attach(sidecarID: "mail", client: client, policy: policy)
        let reader = AttachmentTextReader(router: router, policy: policy, storage: storage)

        let result = await reader.read(arguments: [
            "message_id": .string("account.INBOX.1.2"),
            "part_id": .string("1.2")
        ])

        XCTAssertFalse(result.isError ?? true)
        XCTAssertTrue(resultText(result).contains("Approved content only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls.map(\.0), ["get_attachment"])
        XCTAssertEqual(calls.first?.1?["message_id"], .string("account.INBOX.1.2"))
        XCTAssertEqual(calls.first?.1?["part_id"], .string("1.2"))
        XCTAssertNil(calls.first?.1?["output_dir"])
    }

    func testRejectsSidecarFileOutsidePrivateStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let storage = AttachmentStorage(directoryURL: root.appendingPathComponent("attachments"))
        try storage.prepare()
        try Data("must stay outside".utf8).write(to: outsideURL)

        let response = try downloadResponse(
            fileURL: outsideURL,
            filename: "outside.txt",
            contentType: "text/plain"
        )
        let client = AttachmentSidecarClient(response: response)
        let router = GatewayRouter()
        let policy = attachmentPolicy()
        try await router.attach(sidecarID: "mail", client: client, policy: policy)
        let reader = AttachmentTextReader(router: router, policy: policy, storage: storage)

        let result = await reader.read(arguments: [
            "message_id": .string("account.INBOX.1.2"),
            "part_id": .string("1")
        ])

        XCTAssertTrue(result.isError ?? false)
        XCTAssertEqual(resultText(result), "Unable to read attachment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    private func attachmentPolicy() -> ReaderPolicy {
        ReaderPolicy(rules: [
            ReaderToolRule(
                publicName: AttachmentTextReader.publicToolName,
                sidecarID: "mail",
                upstreamName: "get_attachment",
                allowedArguments: ["message_id", "part_id"]
            )
        ])
    }

    private func downloadResponse(
        fileURL: URL,
        filename: String,
        contentType: String
    ) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "file_path": fileURL.path,
            "filename": filename,
            "content_type": contentType
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _) = result.content.first else { return "" }
        return text
    }
}
