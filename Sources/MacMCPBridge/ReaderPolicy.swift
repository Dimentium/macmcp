import Foundation
import MCP

enum ToolExposure: Equatable, Sendable {
    case reader
    case mailAction
}

struct ReaderToolRule: Equatable, Sendable {
    let publicName: String
    let sidecarID: String
    let upstreamName: String
    let allowedArguments: Set<String>
    let defaultArguments: [String: Value]
    let forcedArguments: [String: Value]
    let maximumIntegers: [String: Int]
    let allowedStrings: [String: Set<String>]
    let exposure: ToolExposure
    let isIdempotent: Bool

    init(
        publicName: String,
        sidecarID: String,
        upstreamName: String,
        allowedArguments: Set<String> = [],
        defaultArguments: [String: Value] = [:],
        forcedArguments: [String: Value] = [:],
        maximumIntegers: [String: Int] = [:],
        allowedStrings: [String: Set<String>] = [:],
        exposure: ToolExposure = .reader,
        isIdempotent: Bool = true
    ) {
        self.publicName = publicName
        self.sidecarID = sidecarID
        self.upstreamName = upstreamName
        self.allowedArguments = allowedArguments
        self.defaultArguments = defaultArguments
        self.forcedArguments = forcedArguments
        self.maximumIntegers = maximumIntegers
        self.allowedStrings = allowedStrings
        self.exposure = exposure
        self.isIdempotent = isIdempotent
    }
}

enum ReaderPolicyError: LocalizedError, Equatable {
    case unavailableTool
    case incompatibleUpstreamSchema(String)
    case unknownArgument(String)
    case invalidArgument(String)
    case argumentTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .unavailableTool:
            return "Unknown or unavailable MacMCP tool"
        case .incompatibleUpstreamSchema(let name):
            return "Pinned sidecar schema is incompatible with the MacMCP policy: \(name)"
        case .unknownArgument(let name):
            return "Argument is not allowed by the MacMCP policy: \(name)"
        case .invalidArgument(let name):
            return "Invalid MacMCP argument: \(name)"
        case .argumentTooLarge(let name):
            return "MacMCP argument exceeds its limit: \(name)"
        }
    }
}

struct ReaderPolicy: Sendable {
    static let mailSidecarID = "mail"
    static let eventKitSidecarID = "eventkit"

    static let rules: [ReaderToolRule] = [
        ReaderToolRule(
            publicName: "mail.list_accounts",
            sidecarID: mailSidecarID,
            upstreamName: "list_accounts"
        ),
        ReaderToolRule(
            publicName: "mail.server_info",
            sidecarID: mailSidecarID,
            upstreamName: "get_server_info"
        ),
        ReaderToolRule(
            publicName: "mail.list_folders",
            sidecarID: mailSidecarID,
            upstreamName: "list_folders",
            allowedArguments: ["account_id"]
        ),
        ReaderToolRule(
            publicName: "mail.search",
            sidecarID: mailSidecarID,
            upstreamName: "search_emails",
            allowedArguments: [
                "account_id", "folder", "from", "to", "subject", "body", "text",
                "since", "before", "unseen", "seen", "flagged", "limit", "offset"
            ],
            defaultArguments: ["limit": .int(25)],
            maximumIntegers: ["limit": 25, "offset": 10_000]
        ),
        ReaderToolRule(
            publicName: "mail.read",
            sidecarID: mailSidecarID,
            upstreamName: "read_email",
            allowedArguments: ["message_id", "max_body_chars"],
            defaultArguments: ["max_body_chars": .int(12_000)],
            forcedArguments: [
                "mark_as_read": .bool(false),
                "include_html": .bool(false),
                "include_headers": .bool(false)
            ],
            maximumIntegers: ["max_body_chars": 12_000]
        ),
        ReaderToolRule(
            publicName: AttachmentTextReader.publicToolName,
            sidecarID: mailSidecarID,
            upstreamName: "get_attachment",
            allowedArguments: ["message_id", "part_id"]
        ),
        ReaderToolRule(
            publicName: "calendar.list",
            sidecarID: eventKitSidecarID,
            upstreamName: "list_calendars",
            allowedArguments: ["type"]
        ),
        ReaderToolRule(
            publicName: "calendar.events",
            sidecarID: eventKitSidecarID,
            upstreamName: "list_events",
            allowedArguments: [
                "start_date", "end_date", "calendar_name", "calendar_source", "filter",
                "sort", "limit", "detail_level", "fields", "display_timezone"
            ],
            defaultArguments: ["limit": .int(100), "detail_level": .string("summary")],
            maximumIntegers: ["limit": 100],
            allowedStrings: ["detail_level": ["summary", "standard"]]
        ),
        ReaderToolRule(
            publicName: "calendar.upcoming",
            sidecarID: eventKitSidecarID,
            upstreamName: "list_events_quick",
            allowedArguments: [
                "range", "week_starts_on", "calendar_name", "calendar_source", "limit",
                "detail_level", "fields", "display_timezone"
            ],
            defaultArguments: ["limit": .int(100), "detail_level": .string("summary")],
            maximumIntegers: ["limit": 100],
            allowedStrings: [
                "detail_level": ["summary", "standard"],
                "range": [
                    "today", "tomorrow", "this_week", "next_week", "this_month",
                    "next_7_days", "next_30_days"
                ],
                "week_starts_on": ["system", "monday", "sunday", "saturday"]
            ]
        ),
        ReaderToolRule(
            publicName: "calendar.search",
            sidecarID: eventKitSidecarID,
            upstreamName: "search_events",
            allowedArguments: [
                "keyword", "keywords", "match_mode", "start_date", "end_date",
                "calendar_name", "calendar_source", "limit", "detail_level", "fields", "display_timezone"
            ],
            defaultArguments: ["limit": .int(100), "detail_level": .string("summary")],
            maximumIntegers: ["limit": 100],
            allowedStrings: ["detail_level": ["summary", "standard"]]
        ),
        ReaderToolRule(
            publicName: "reminders.list",
            sidecarID: eventKitSidecarID,
            upstreamName: "list_reminders",
            allowedArguments: [
                "completed", "filter", "sort", "limit", "calendar_name", "calendar_source"
            ],
            defaultArguments: ["limit": .int(10)],
            maximumIntegers: ["limit": 100]
        ),
        ReaderToolRule(
            publicName: "reminders.search",
            sidecarID: eventKitSidecarID,
            upstreamName: "search_reminders",
            allowedArguments: [
                "keyword", "keywords", "match_mode", "tag", "calendar_name",
                "calendar_source", "completed", "limit"
            ],
            defaultArguments: ["limit": .int(100)],
            maximumIntegers: ["limit": 100]
        ),
        ReaderToolRule(
            publicName: "reminders.tags",
            sidecarID: eventKitSidecarID,
            upstreamName: "list_reminder_tags",
            allowedArguments: ["calendar_name", "calendar_source", "include_completed"]
        )
    ]

    static let mailActionRules: [ReaderToolRule] = [
        ReaderToolRule(
            publicName: "mail.create_managed_draft",
            sidecarID: mailSidecarID,
            upstreamName: "create_managed_draft",
            allowedArguments: ["account_id", "subject", "body_text", "body_html"],
            exposure: .mailAction,
            isIdempotent: false
        ),
        ReaderToolRule(
            publicName: "mail.update_managed_draft",
            sidecarID: mailSidecarID,
            upstreamName: "update_managed_draft",
            allowedArguments: ["message_id", "revision", "subject", "body_text", "body_html"],
            exposure: .mailAction,
            isIdempotent: false
        ),
        ReaderToolRule(
            publicName: "mail.mark",
            sidecarID: mailSidecarID,
            upstreamName: "mark_email",
            allowedArguments: ["message_id", "action"],
            allowedStrings: ["action": ["read", "unread", "flagged", "unflagged"]],
            exposure: .mailAction,
            isIdempotent: true
        )
    ]

    static let allRules = rules + mailActionRules
    static let mailActionToolNames = Set(mailActionRules.map(\.publicName))

    private let rulesByName: [String: ReaderToolRule]

    init(rules: [ReaderToolRule] = ReaderPolicy.rules) {
        rulesByName = Dictionary(uniqueKeysWithValues: rules.map { ($0.publicName, $0) })
    }

    func rules(for sidecarID: String) -> [ReaderToolRule] {
        rulesByName.values
            .filter { $0.sidecarID == sidecarID }
            .sorted { $0.publicName < $1.publicName }
    }

    var publicToolNames: Set<String> {
        Set(rulesByName.keys)
    }

    func rule(for publicName: String) throws -> ReaderToolRule {
        guard let rule = rulesByName[publicName] else {
            throw ReaderPolicyError.unavailableTool
        }
        return rule
    }

    func prepareArguments(
        for publicName: String,
        supplied: [String: Value]?
    ) throws -> [String: Value] {
        let rule = try rule(for: publicName)
        var result = rule.defaultArguments

        for (name, value) in supplied ?? [:] {
            guard rule.allowedArguments.contains(name) else {
                throw ReaderPolicyError.unknownArgument(name)
            }
            try validate(value: value, argument: name, depth: 0)

            let normalizedValue = normalize(
                value: value,
                argument: name,
                for: publicName
            )

            if let maximum = rule.maximumIntegers[name] {
                guard let integer = normalizedValue.intValue, integer >= 0 else {
                    throw ReaderPolicyError.invalidArgument(name)
                }
                result[name] = .int(min(integer, maximum))
            } else {
                if let allowed = rule.allowedStrings[name] {
                    guard let string = normalizedValue.stringValue, allowed.contains(string) else {
                        throw ReaderPolicyError.invalidArgument(name)
                    }
                }
                result[name] = normalizedValue
            }
        }

        for (name, value) in rule.forcedArguments {
            result[name] = value
        }
        return result
    }

    private func normalize(value: Value, argument: String, for publicName: String) -> Value {
        guard publicName == "calendar.upcoming", argument == "range",
              let range = value.stringValue
        else {
            return value
        }

        // CheICalMCP defaults unknown ranges to `today`. Accept the compact
        // form agents commonly produce, but always send the sidecar's exact,
        // bounded shortcut name so a requested multi-day window is not lost.
        switch range {
        case "7d":
            return .string("next_7_days")
        case "30d":
            return .string("next_30_days")
        default:
            return value
        }
    }

    func project(upstream: Tool, using rule: ReaderToolRule) throws -> Tool {
        guard upstream.name == rule.upstreamName else {
            throw ReaderPolicyError.unavailableTool
        }

        guard let root = upstream.inputSchema.objectValue else {
            throw ReaderPolicyError.incompatibleUpstreamSchema(rule.upstreamName)
        }

        let properties: [String: Value]
        if let declaredProperties = root["properties"] {
            guard let object = declaredProperties.objectValue else {
                throw ReaderPolicyError.incompatibleUpstreamSchema(rule.upstreamName)
            }
            properties = object
        } else {
            // JSON Schema permits an object schema with no explicit
            // `properties`. mail-mcp uses that equivalent form for its
            // zero-argument tools.
            guard rule.allowedArguments.isEmpty, rule.forcedArguments.isEmpty else {
                throw ReaderPolicyError.incompatibleUpstreamSchema(rule.upstreamName)
            }
            properties = [:]
        }

        // Forced arguments are safety interlocks, not presentation hints. If a
        // pinned sidecar removes or renames one of them, refuse to expose the
        // tool until the policy is reviewed against that exact version.
        if rule.forcedArguments.keys.contains(where: { properties[$0] == nil }) {
            throw ReaderPolicyError.incompatibleUpstreamSchema(rule.upstreamName)
        }

        let narrowedSchema = narrowSchema(
            upstream.inputSchema,
            allowedArguments: rule.allowedArguments,
            maximumIntegers: rule.maximumIntegers,
            allowedStrings: rule.allowedStrings
        )

        let description = MacMCPServerMetadata.toolDescription(
            for: rule.publicName,
            exposure: rule.exposure
        )

        return Tool(
            name: rule.publicName,
            title: rule.publicName,
            description: description,
            inputSchema: narrowedSchema,
            annotations: .init(
                readOnlyHint: rule.exposure == .reader,
                destructiveHint: false,
                idempotentHint: rule.isIdempotent,
                openWorldHint: false
            ),
            outputSchema: ReaderOutputSchema.untrustedData
        )
    }

    private func narrowSchema(
        _ schema: Value,
        allowedArguments: Set<String>,
        maximumIntegers: [String: Int],
        allowedStrings: [String: Set<String>]
    ) -> Value {
        guard let root = schema.objectValue else {
            return .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ])
        }

        let originalProperties = root["properties"]?.objectValue ?? [:]
        var properties: [String: Value] = [:]
        for name in allowedArguments {
            guard let original = originalProperties[name]?.objectValue else { continue }
            // Keep only structural type information. Titles, descriptions,
            // patterns, defaults, metadata, and output schemas are supplied by
            // the sidecar and must not become an instruction channel.
            var property: [String: Value] = [:]
            if let type = original["type"]?.stringValue {
                property["type"] = .string(type)
            }
            if let itemType = original["items"]?.objectValue?["type"]?.stringValue {
                property["items"] = .object(["type": .string(itemType)])
            }
            if let maximum = maximumIntegers[name] {
                property["maximum"] = .int(maximum)
                property["minimum"] = .int(0)
            }
            if let allowed = allowedStrings[name] {
                property["enum"] = .array(allowed.sorted().map(Value.string))
            }
            properties[name] = .object(property)
        }

        var narrowedRoot: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]

        if let required = root["required"]?.arrayValue {
            let filtered = required.filter {
                guard let name = $0.stringValue else { return false }
                return allowedArguments.contains(name)
            }
            if filtered.isEmpty {
                narrowedRoot.removeValue(forKey: "required")
            } else {
                narrowedRoot["required"] = .array(filtered)
            }
        }

        return .object(narrowedRoot)
    }

    private func validate(value: Value, argument: String, depth: Int) throws {
        guard depth <= 3 else { throw ReaderPolicyError.argumentTooLarge(argument) }

        switch value {
        case .null, .bool, .int, .double:
            return
        case .string(let string):
            guard string.utf8.count <= 4_096 else {
                throw ReaderPolicyError.argumentTooLarge(argument)
            }
        case .array(let values):
            guard values.count <= 32 else {
                throw ReaderPolicyError.argumentTooLarge(argument)
            }
            for item in values {
                try validate(value: item, argument: argument, depth: depth + 1)
            }
        case .object(let object):
            guard object.count <= 32 else {
                throw ReaderPolicyError.argumentTooLarge(argument)
            }
            for item in object.values {
                try validate(value: item, argument: argument, depth: depth + 1)
            }
        case .data:
            throw ReaderPolicyError.invalidArgument(argument)
        }
    }
}
