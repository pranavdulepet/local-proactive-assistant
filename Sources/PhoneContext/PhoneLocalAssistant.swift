import AppleModelAdapter
import Foundation
import LocalInference

/// Optional on-phone inference while the companion app is open.
public actor PhoneLocalAssistant {
    private let source: PhoneContextSource
    private let provider: AppleSystemModelProvider
    private var history: [ChatTurn] = []

    public init(source: PhoneContextSource = PhoneContextSource(), provider: AppleSystemModelProvider = AppleSystemModelProvider()) {
        self.source = source
        self.provider = provider
    }

    public func availability() async -> ModelAvailability { await provider.availability() }

    public func answer(_ text: String, contactName: String = "") async throws -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 512 else {
            throw LocalModelFailure("Enter a message of at most 512 bytes.")
        }
        let availability = await provider.availability()
        guard availability.ready else { throw LocalModelFailure(availability.detail) }
        let lower = message.lowercased()
        let evidence = try await source.request(
            question: message, contactName: contactName,
            includeCalendar: lower.contains("calendar") || lower.contains("schedule"),
            includeContacts: !contactName.isEmpty,
            includeSleep: lower.contains("sleep") || lower.contains("slept")
        )
        let reply: String
        if message.hasSuffix("?"), !evidence.records.isEmpty {
            reply = try await AnswerService(provider: provider).answer(evidence).text
        } else {
            let request = ChatRequest(
                message: message, history: history,
                records: evidence.records, coverage: evidence.coverage
            )
            reply = try await provider.chat(request).text
        }
        history.append(ChatTurn(role: .user, text: message))
        history.append(ChatTurn(role: .assistant, text: EvidenceText.bounded(reply, bytes: 512)))
        history = Array(history.suffix(8))
        return reply
    }
}
