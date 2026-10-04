import AssistantCore
import Foundation
import LocalInference

/// One foreground answer per route. Generation never holds up the command listener.
public actor ModelConversationService {
    private let store: ObservationStore
    private let provider: any LocalModelProvider
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let chatID: TransportChatID
    private let history: ConversationHistory
    private var active: Task<Void, Never>?

    public init(
        store: ObservationStore, provider: any LocalModelProvider,
        transport: any MessageTransport, ledger: OutboundLedger,
        chatID: TransportChatID, history: ConversationHistory? = nil
    ) {
        self.store = store
        self.provider = provider
        self.transport = transport
        self.ledger = ledger
        self.chatID = chatID
        self.history = history ?? (ConversationHistory())
    }

    public func begin(question: String) -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 512 else { return "Send a message of at most 512 bytes." }
        guard active == nil else { return "A local answer is already in progress. Owner commands still work." }
        active = Task { await self.run(message: question) }
        return "Let me check."
    }

    public func cancel() {
        active?.cancel()
    }

    private func run(message: String) async {
        defer { active = nil }
        var reply: String
        do {
            let previous = await history.lastUserMessage()
            let query = Self.retrievalQuery(message, previous: previous)
            let request = try await EvidenceRetriever(store: store).request(question: query)
            if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"),
               !request.records.isEmpty {
                reply = try await AnswerService(provider: provider).answer(request).text
            } else {
                let chat = ChatRequest(
                    message: message, history: await history.recent(),
                    records: request.records, coverage: request.coverage
                )
                try chat.validate()
                reply = try await provider.chat(chat).text
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            reply = "I couldn't answer locally right now. Check model-status on the Mac and try again."
        }
        do {
            let outbound = OutboundTransportMessage(text: reply)
            try await ledger.begin(requestID: outbound.requestID, chatID: chatID, text: outbound.text)
            // Recipient is fixed by verified host configuration, never model output.
            let receipt = try await transport.send(outbound, to: chatID)
            try await ledger.confirm(requestID: outbound.requestID, messageGUID: receipt.messageGUID)
            try await history.append(user: message, assistant: reply)
            print("local answer submitted (not a delivery confirmation)")
        } catch {
            print("local answer send outcome unknown; no automatic resend")
        }
    }

    private static func retrievalQuery(_ message: String, previous: String?) -> String {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let follows = lower.hasPrefix("and ") || lower.hasPrefix("what about")
            || lower.hasPrefix("tell me more") || lower.hasPrefix("when is it")
            || lower.hasPrefix("who is that")
        guard follows, let previous else { return message }
        return EvidenceText.bounded(previous + " " + message, bytes: 512)
    }
}
