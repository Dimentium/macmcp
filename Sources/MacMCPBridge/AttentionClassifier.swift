import Foundation

enum AttentionCategory: String, Codable, CaseIterable, Sendable {
    case personal
    case workDeadline = "work_deadline"
    case paymentsSecurity = "payments_security"
    case schoolMedicalFamily = "school_medical_family"
}

enum AttentionUrgency: String, Codable, Comparable, Hashable, Sendable {
    case none
    case normal
    case immediate

    static func < (lhs: AttentionUrgency, rhs: AttentionUrgency) -> Bool {
        let rank: [AttentionUrgency: Int] = [.none: 0, .normal: 1, .immediate: 2]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

enum AttentionReasonCode: String, Codable, Sendable {
    case noAttentionSignal = "no_attention_signal"
    case likelyHumanSender = "likely_human_sender"
    case workRequestOrDeadline = "work_request_or_deadline"
    case paymentOrSecurity = "payment_or_security"
    case schoolMedicalOrFamily = "school_medical_or_family"
}

struct AttentionMessage: Equatable, Sendable {
    let sender: String
    let subject: String
    let body: String
    let hasListUnsubscribe: Bool
}

struct AttentionDecision: Codable, Equatable, Sendable {
    let needsAttention: Bool
    let categories: [AttentionCategory]
    let urgency: AttentionUrgency
    let reasonCode: AttentionReasonCode
    let confidence: Double
}

protocol AttentionClassifying: Sendable {
    func classify(_ message: AttentionMessage) -> AttentionDecision
}

/// A zero-tool, deterministic baseline. It intentionally returns trusted reason
/// codes rather than quoting attacker-controlled text in notifications or logs.
struct ToollessAttentionClassifier: AttentionClassifying {
    func classify(_ message: AttentionMessage) -> AttentionDecision {
        let sender = normalize(message.sender)
        let text = normalize(message.subject + "\n" + message.body)
        var categories: [AttentionCategory] = []

        if matches(text, any: Self.paymentSecurityTerms) {
            categories.append(.paymentsSecurity)
        }
        if matches(text, any: Self.schoolMedicalFamilyTerms) {
            categories.append(.schoolMedicalFamily)
        }
        if matches(text, any: Self.workTerms) {
            categories.append(.workDeadline)
        }

        let automated = message.hasListUnsubscribe || matches(sender, any: Self.automatedSenderTerms)
        let promotional = matches(text, any: Self.promotionalTerms)
        if !automated && !promotional {
            categories.append(.personal)
        }

        categories = AttentionCategory.allCases.filter(categories.contains)
        guard !categories.isEmpty else {
            return AttentionDecision(
                needsAttention: false,
                categories: [],
                urgency: .none,
                reasonCode: .noAttentionSignal,
                confidence: 0.75
            )
        }

        let urgent = matches(text, any: Self.immediateTerms)
        let reason: AttentionReasonCode
        if categories.contains(.paymentsSecurity) {
            reason = .paymentOrSecurity
        } else if categories.contains(.schoolMedicalFamily) {
            reason = .schoolMedicalOrFamily
        } else if categories.contains(.workDeadline) {
            reason = .workRequestOrDeadline
        } else {
            reason = .likelyHumanSender
        }

        return AttentionDecision(
            needsAttention: true,
            categories: categories,
            urgency: urgent ? .immediate : .normal,
            reasonCode: reason,
            confidence: automated ? 0.82 : 0.68
        )
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func matches(_ text: String, any terms: [String]) -> Bool {
        terms.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static let automatedSenderTerms = [
        "no-reply", "noreply", "do-not-reply", "mailer-daemon", "notifications@",
        "newsletter@", "marketing@"
    ]
    private static let promotionalTerms = [
        "unsubscribe", "отписаться", "sale", "скидк", "promo", "реклам"
    ]
    private static let workTerms = [
        "deadline", "due date", "action required", "please review", "request",
        "дедлайн", "срок", "нужно согласовать", "прошу проверить", "задач"
    ]
    private static let paymentSecurityTerms = [
        "invoice", "payment due", "receipt", "billing", "security alert", "sign-in",
        "счет", "счёт", "оплат", "квитанц", "безопасност", "вход в аккаунт"
    ]
    private static let schoolMedicalFamilyTerms = [
        "school", "teacher", "parent", "doctor", "clinic", "appointment", "family",
        "школ", "учител", "родител", "врач", "клиник", "прием", "приём", "семь"
    ]
    private static let immediateTerms = [
        "urgent", "immediately", "today", "overdue", "action required", "security alert",
        "срочно", "немедленно", "сегодня", "просроч", "безопасност"
    ]
}
