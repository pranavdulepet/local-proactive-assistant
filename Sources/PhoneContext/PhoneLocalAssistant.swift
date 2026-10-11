import AppleModelAdapter
import Foundation
import LocalInference

/// Optional on-phone inference while the companion app is open.
public actor PhoneLocalAssistant {
    private let source: PhoneContextSource
    private let provider: any LocalModelProvider
    private var history: [ChatTurn] = []
    private var nextEvidenceID = 1
    private var answering = false

    public init(source: PhoneContextSource = PhoneContextSource(), provider: any LocalModelProvider = AppleSystemModelProvider()) {
        self.source = source
        self.provider = provider
    }

    public func availability() async -> ModelAvailability { await provider.availability() }

    public func answer(_ text: String, contactName: String = "", includeCalendar: Bool = false,
                       includeSleep: Bool = false, includeActivity: Bool = false,
                       includeLocation: Bool = false) async throws -> String {
        guard !answering else { throw LocalModelFailure("A local phone reply is already in progress.") }
        answering = true
        defer { answering = false }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 4_096 else {
            throw LocalModelFailure("Enter a message of at most 4,096 UTF-8 bytes.")
        }
        let availability = await provider.availability()
        guard availability.ready else { throw LocalModelFailure(availability.detail) }
        let evidence = try await source.request(
            question: EvidenceText.bounded(message, bytes: 512), contactName: contactName,
            includeCalendar: includeCalendar,
            includeContacts: !contactName.isEmpty,
            includeSleep: includeSleep, includeActivity: includeActivity,
            includeLocation: includeLocation
        )
        let records = evidence.records.enumerated().map { index, record in
            EvidenceRecord(id: "e\(nextEvidenceID + index)", source: record.source, timestamp: record.timestamp,
                text: record.text, locator: record.locator, trust: record.trust)
        }
        let request = ChatRequest(message: message, history: history,
            records: records, coverage: evidence.coverage)
        try request.validate()
        let response = try await provider.chat(request)
        try response.validate(for: request)
        let reply = response.text
        nextEvidenceID += records.count
        history.append(ChatTurn(role: .user, text: message))
        history.append(ChatTurn(role: .assistant, text: EvidenceText.bounded(reply, bytes: 2_048)))
        history = history.map { ChatTurn(role: $0.role, text: EvidenceText.bounded($0.text, bytes: 2_048)) }
        history = Array(history.suffix(8))
        return reply
    }
}
