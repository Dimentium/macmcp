import Foundation
import MCP
import XCTest
@testable import MacMCPBridge

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

    func testUnifiedToolSurfaceIncludesMailActions() {
        XCTAssertEqual(
            ReaderPolicy.allRules.map(\.publicName).suffix(3),
            ["mail.create_managed_draft", "mail.update_managed_draft", "mail.mark"]
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

    func testReminderListUsesACompactDefault() throws {
        let arguments = try ReaderPolicy().prepareArguments(
            for: "reminders.list",
            supplied: nil
        )
        XCTAssertEqual(arguments["limit"], .int(10))
    }

    func testCalendarDetailDefaultsToSummaryButAllowsStandardAndFields() throws {
        let selectedFields: [Value] = [
            .string("title"), .string("notes"), .string("location"),
            .string("url"), .string("structured_location"), .string("attendees"),
            .string("organizer")
        ]
        let policy = ReaderPolicy()

        for toolName in ["calendar.events", "calendar.upcoming", "calendar.search"] {
            let arguments = try policy.prepareArguments(
                for: toolName,
                supplied: ["limit": .int(5)]
            )
            XCTAssertEqual(arguments["detail_level"], .string("summary"), toolName)

            let detailed = try policy.prepareArguments(
                for: toolName,
                supplied: ["detail_level": .string("standard")]
            )
            XCTAssertEqual(detailed["detail_level"], .string("standard"), toolName)

            let selected = try policy.prepareArguments(
                for: toolName,
                supplied: ["fields": .array(selectedFields)]
            )
            XCTAssertEqual(selected["fields"], .array(selectedFields), toolName)
        }
    }

    func testUpcomingCalendarRangeUsesBoundedShortcutsAndNormalizesCommonAliases() throws {
        let policy = ReaderPolicy()

        let normalized = try policy.prepareArguments(
            for: "calendar.upcoming",
            supplied: ["range": .string("7d")]
        )
        XCTAssertEqual(normalized["range"], .string("next_7_days"))

        let thirtyDays = try policy.prepareArguments(
            for: "calendar.upcoming",
            supplied: ["range": .string("30d")]
        )
        XCTAssertEqual(thirtyDays["range"], .string("next_30_days"))

        XCTAssertThrowsError(
            try policy.prepareArguments(
                for: "calendar.upcoming",
                supplied: ["range": .string("6d")]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .invalidArgument("range"))
        }
    }

    func testUpcomingCalendarSchemaPublishesSupportedRangeShortcuts() throws {
        let upstream = Tool(
            name: "list_events_quick",
            description: "Quick calendar ranges",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "range": .object(["type": .string("string")]),
                    "week_starts_on": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "detail_level": .object(["type": .string("string")]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ])
        )

        let policy = ReaderPolicy()
        let projected = try policy.project(upstream: upstream, using: policy.rule(for: "calendar.upcoming"))
        let range = projected.inputSchema.objectValue?["properties"]?.objectValue?["range"]?.objectValue

        XCTAssertEqual(
            range?["enum"],
            .array([
                .string("next_30_days"), .string("next_7_days"), .string("next_week"),
                .string("this_month"), .string("this_week"), .string("today"), .string("tomorrow")
            ])
        )

        let properties = projected.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertEqual(
            properties?["detail_level"]?.objectValue?["enum"],
            .array([.string("standard"), .string("summary")])
        )
        XCTAssertEqual(properties?["fields"]?.objectValue?["type"], .string("array"))
        XCTAssertEqual(
            properties?["fields"]?.objectValue?["items"],
            .object(["type": .string("string")])
        )
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

    func testMailActionPolicyAllowsOnlyDeclaredFlagActions() throws {
        let policy = ReaderPolicy(rules: ReaderPolicy.mailActionRules)
        XCTAssertEqual(policy.publicToolNames, [
            "mail.create_managed_draft", "mail.update_managed_draft", "mail.mark"
        ])
        XCTAssertEqual(
            try policy.prepareArguments(
                for: "mail.mark",
                supplied: ["message_id": .string("opaque"), "action": .string("flagged")]
            )["action"],
            .string("flagged")
        )
        XCTAssertThrowsError(
            try policy.prepareArguments(
                for: "mail.mark",
                supplied: ["message_id": .string("opaque"), "action": .string("answered")]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .invalidArgument("action"))
        }
        XCTAssertThrowsError(
            try policy.prepareArguments(
                for: "mail.create_managed_draft",
                supplied: ["to": .array([.string("person@example.com")])]
            )
        ) { error in
            XCTAssertEqual(error as? ReaderPolicyError, .unknownArgument("to"))
        }
    }

    func testMailActionProjectionMarksMutatingToolAndNarrowedEnum() throws {
        let upstream = Tool(
            name: "mark_email",
            description: "Change any message flag",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message_id": .object(["type": .string("string")]),
                    "action": .object(["type": .string("string")])
                ]),
                "required": .array([.string("message_id"), .string("action")])
            ])
        )
        let policy = ReaderPolicy(rules: ReaderPolicy.mailActionRules)
        let projected = try policy.project(upstream: upstream, using: policy.rule(for: "mail.mark"))

        XCTAssertEqual(projected.annotations.readOnlyHint, false)
        XCTAssertEqual(projected.annotations.idempotentHint, true)
        XCTAssertEqual(
            projected.inputSchema.objectValue?["properties"]?.objectValue?["action"]?.objectValue?["enum"],
            .array([.string("flagged"), .string("read"), .string("unflagged"), .string("unread")])
        )
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
        XCTAssertTrue(projected.description?.contains("local macOS Mail") == true)
        XCTAssertTrue(projected.description?.contains("mail.search") == true)
    }

    func testProjectedDescriptionsRouteNaturalLanguageDomains() throws {
        let cases = [
            ("mail.search", "new, recent, unread"),
            ("calendar.upcoming", "calendar today"),
            ("reminders.list", "local Apple Reminders")
        ]

        for (name, expectedPhrase) in cases {
            XCTAssertTrue(
                MacMCPServerMetadata.toolDescription(for: name, exposure: .reader).contains(expectedPhrase),
                "Expected \(name) description to contain \(expectedPhrase)"
            )
        }
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
