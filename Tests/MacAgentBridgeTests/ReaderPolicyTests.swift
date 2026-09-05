import Foundation
import MCP
import XCTest
@testable import MacAgentBridge

final class ReaderPolicyTests: XCTestCase {
    func testReaderToolSurfaceIsAnExactSnapshot() {
        XCTAssertEqual(
            ReaderPolicy.rules.map(\.publicName),
            [
                "mail.list_accounts",
                "mail.server_info",
                "mail.list_folders",
                "mail.search",
                "mail.read",
                "mail.read_attachment_text",
                "calendar.list",
                "calendar.events",
                "calendar.upcoming",
                "calendar.search",
                "reminders.list",
                "reminders.search",
                "reminders.tags"
            ]
        )
    }

    func testMailReadForcesNonMutatingArguments() throws {
        let arguments = try ReaderPolicy().prepareArguments(
            for: "mail.read",
            supplied: ["message_id": .string("opaque")]
        )

        XCTAssertEqual(arguments["mark_as_read"], .bool(false))
        XCTAssertEqual(arguments["include_html"], .bool(false))
        XCTAssertEqual(arguments["include_headers"], .bool(false))
        XCTAssertEqual(arguments["max_body_chars"], .int(12_000))
    }

    func testMailReadRejectsMarkAsReadEvenWhenFalse() {
        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(
                for: "mail.read",
                supplied: ["mark_as_read": .bool(false)]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unknownArgument("mark_as_read"))
        }
    }

    func testAttachmentReaderRejectsSidecarOutputDirectory() {
        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(
                for: "mail.read_attachment_text",
                supplied: ["output_dir": .string("/tmp")]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unknownArgument("output_dir"))
        }
    }

    func testSearchLimitIsClamped() throws {
        let arguments = try ReaderPolicy().prepareArguments(
            for: "mail.search",
            supplied: ["limit": .int(10_000)]
        )
        XCTAssertEqual(arguments["limit"], .int(25))
    }

    func testCalendarDetailIsForcedToSummary() throws {
        let arguments = try ReaderPolicy().prepareArguments(
            for: "calendar.events",
            supplied: ["limit": .int(5)]
        )
        XCTAssertEqual(arguments["detail_level"], .string("summary"))

        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(
                for: "calendar.events",
                supplied: ["detail_level": .string("standard")]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unknownArgument("detail_level"))
        }
    }

    func testUnknownToolsAndArgumentsFailClosed() {
        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(for: "mail.delete", supplied: nil)
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unavailableTool)
        }

        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(
                for: "mail.search",
                supplied: ["surprise": .string("value")]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unknownArgument("surprise"))
        }
    }

    func testProjectedSchemaRemovesMutationFields() throws {
        let upstream = Tool(
            name: "read_email",
            description: "Read email",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message_id": .object(["type": .string("string")]),
                    "mark_as_read": .object(["type": .string("boolean")]),
                    "include_html": .object(["type": .string("boolean")]),
                    "include_headers": .object(["type": .string("boolean")]),
                    "max_body_chars": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("message_id")])
            ])
        )
        let policy = ReaderPolicy()
        let rule = try policy.rule(for: "mail.read")
        let projected = try policy.project(upstream: upstream, using: rule)
        let root = projected.inputSchema.objectValue
        let properties = root?["properties"]?.objectValue

        XCTAssertNotNil(properties?["message_id"])
        XCTAssertNotNil(properties?["max_body_chars"])
        XCTAssertNil(properties?["mark_as_read"])
        XCTAssertNil(properties?["include_html"])
        XCTAssertNil(properties?["include_headers"])
        XCTAssertEqual(root?["additionalProperties"], .bool(false))
        XCTAssertEqual(projected.annotations.readOnlyHint, true)
        XCTAssertEqual(projected.outputSchema, ReaderOutputSchema.untrustedData)
        XCTAssertFalse(projected.description?.contains("Read email") ?? true)
    }

    func testZeroArgumentToolAcceptsObjectSchemaWithoutProperties() throws {
        let upstream = Tool(
            name: "list_accounts",
            description: "List accounts",
            inputSchema: .object(["type": .string("object")])
        )
        let policy = ReaderPolicy()
        let rule = try policy.rule(for: "mail.list_accounts")
        let projected = try policy.project(upstream: upstream, using: rule)

        XCTAssertEqual(projected.inputSchema.objectValue?["properties"], .object([:]))
        XCTAssertEqual(projected.inputSchema.objectValue?["additionalProperties"], .bool(false))
    }

    func testBinaryDataArgumentsAreRejected() {
        XCTAssertThrowsError(
            try ReaderPolicy().prepareArguments(
                for: "mail.search",
                supplied: ["subject": .data(Data([0x00]))]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .invalidArgument("subject"))
        }
    }

    func testMissingSafetyInterlockFailsClosed() throws {
        let upstream = Tool(
            name: "read_email",
            description: "Changed upstream",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message_id": .object(["type": .string("string")])
                ])
            ])
        )
        let policy = ReaderPolicy()
        let rule = try policy.rule(for: "mail.read")

        XCTAssertThrowsError(try policy.project(upstream: upstream, using: rule)) { error in
            XCTAssertEqual(
                error as? ReaderPolicyError,
                .incompatibleUpstreamSchema("read_email")
            )
        }
    }
}
