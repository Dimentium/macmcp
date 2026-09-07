import Foundation
import MCP

struct AttentionNotification: Equatable, Sendable {
    let opaqueMessageID: String
    let headerMessageID: String?
    let decision: AttentionDecision
}

protocol AttentionNotificationPosting: Sendable {
    func post(_ notification: AttentionNotification) async throws
}

struct MailScanResult: Equatable, Sendable {
    let found: Int
    let processed: Int
    let notified: Int
    let establishedBaseline: Bool
}

enum MailScannerError: LocalizedError, Equatable {
    case sidecarError
    case unsupportedResponse
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .sidecarError:
            return "Mail reader sidecar returned an error"
        case .unsupportedResponse:
            return "Mail reader sidecar returned unsupported content"
        case .malformedResponse:
            return "Mail reader sidecar returned malformed JSON"
        }
    }
}

private struct SearchPayload: Decodable {
    let messages: [SearchMessage]
}

private struct SearchMessage: Decodable {
    let messageID: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

private struct ReadPayload: Decodable {
    let message: ReadMessage
}

private struct ReadMessage: Decodable {
    let from: String
    let subject: String
    let bodyText: String
    let headerMessageID: String?

    enum CodingKeys: String, CodingKey {
        case from, subject
        case bodyText = "body_text"
        case headerMessageID = "message_id_header"
    }
}

actor MailScanner {
    private let router: GatewayRouter
    private let policy: ReaderPolicy
    private let state: MonitorStateStore
    private let classifier: any AttentionClassifying
    private let notifications: any AttentionNotificationPosting

    init(
        router: GatewayRouter,
        policy: ReaderPolicy,
        state: MonitorStateStore,
        classifier: any AttentionClassifying = ToollessAttentionClassifier(),
        notifications: any AttentionNotificationPosting
    ) {
        self.router = router
        self.policy = policy
        self.state = state
        self.classifier = classifier
        self.notifications = notifications
    }

    func scan(accountID: String = "icloud", folder: String = "INBOX") async throws -> MailScanResult {
        let searchResult = try await router.callRaw(
            publicName: "mail.search",
            arguments: [
                "account_id": .string(accountID),
                "folder": .string(folder),
                "limit": .int(25)
            ],
            policy: policy
        )
        let payload: SearchPayload = try decode(searchResult)
        let parsed = try payload.messages.map {
            (message: $0, handle: try MessageHandle(opaqueValue: $0.messageID))
        }.sorted { $0.handle.uid < $1.handle.uid }
        let handles = parsed.map(\.handle)

        let hasCheckpoint = await state.checkpoint(account: accountID, mailbox: folder) != nil
        if !hasCheckpoint {
            try await state.establishBaseline(handles)
            return MailScanResult(
                found: handles.count,
                processed: 0,
                notified: 0,
                establishedBaseline: true
            )
        }

        var processed = 0
        var notified = 0
        for (message, handle) in parsed {
            guard await state.shouldProcess(handle) else { continue }

            let readResult = try await router.callRaw(
                publicName: "mail.read",
                arguments: ["message_id": .string(message.messageID)],
                policy: policy
            )
            let read: ReadPayload = try decode(readResult)
            let decision = classifier.classify(
                AttentionMessage(
                    sender: read.message.from,
                    subject: read.message.subject,
                    body: QuotedReplyLimiter().limitMailReadJSONBody(read.message.bodyText),
                    hasListUnsubscribe: false
                )
            )

            if await state.shouldNotify(opaqueMessageID: message.messageID, decision: decision) {
                try await notifications.post(
                    AttentionNotification(
                        opaqueMessageID: message.messageID,
                        headerMessageID: read.message.headerMessageID,
                        decision: decision
                    )
                )
                notified += 1
            }
            _ = try await state.observe(opaqueMessageID: message.messageID, decision: decision)
            processed += 1
        }

        return MailScanResult(
            found: handles.count,
            processed: processed,
            notified: notified,
            establishedBaseline: false
        )
    }

    private func decode<T: Decodable>(_ result: CallTool.Result) throws -> T {
        guard result.isError != true else { throw MailScannerError.sidecarError }
        guard result.content.count == 1,
              case .text(let text, _, _) = result.content[0]
        else { throw MailScannerError.unsupportedResponse }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { throw MailScannerError.malformedResponse }
        return decoded
    }
}

extension QuotedReplyLimiter {
    func limitMailReadJSONBody(_ body: String) -> String {
        limitBodyForScanner(body)
    }

    private func limitBodyForScanner(_ body: String) -> String {
        // Reuse the JSON implementation so the monitor and agent paths keep
        // identical body/quote budgets without exposing the private helper.
        let object = ["body_text": body]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let source = String(data: data, encoding: .utf8),
              let limitedData = limitMailReadJSON(source).data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: limitedData) as? [String: Any],
              let limited = decoded["body_text"] as? String
        else { return String(body.prefix(bodyCharacterLimit)) }
        return limited
    }
}
