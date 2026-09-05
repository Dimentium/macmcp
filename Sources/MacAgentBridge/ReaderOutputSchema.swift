import MCP

enum ReaderOutputSchema {
    /// Personal data is intentionally opaque to the bridge. The model still
    /// receives the datamarked text for compatibility, while this schema lets
    /// MCP clients identify its source without treating its fields as trusted.
    static let untrustedData = Value.object([
        "type": .string("object"),
        "properties": .object([
            "source": .object([
                "type": .string("string")
            ]),
            "untrusted_data": .object([
                "type": .string("string")
            ])
        ]),
        "required": .array([
            .string("source"),
            .string("untrusted_data")
        ]),
        "additionalProperties": .bool(false)
    ])

    static let bridgeStatus = Value.object([
        "type": .string("object"),
        "properties": .object([
            "version": .object(["type": .string("string")]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("reader")])
            ]),
            "mail": componentState,
            "calendar": componentState,
            "reminders": componentState,
            "writeCapabilitiesEnabled": .object(["type": .string("boolean")])
        ]),
        "required": .array([
            .string("version"),
            .string("mode"),
            .string("mail"),
            .string("calendar"),
            .string("reminders"),
            .string("writeCapabilitiesEnabled")
        ]),
        "additionalProperties": .bool(false)
    ])

    private static let componentState = Value.object([
        "type": .string("string"),
        "enum": .array([
            .string("not_configured"),
            .string("connected_unverified"),
            .string("ready"),
            .string("unavailable")
        ])
    ])

    static func untrustedDataResult(source: String, data: String) -> Value {
        .object([
            "source": .string(source),
            "untrusted_data": .string(data)
        ])
    }
}
