import AssistantCore
import Foundation
import LocalInference

/// One bounded conversation queue across verified self-chat routes. Generation never holds up commands.
public actor ModelConversationService {
    private let store: ObservationStore
    private let provider: any LocalModelProvider
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let defaultChatID: TransportChatID
    private let history: ConversationHistory
    private var active: Task<Void, Never>?
    private var pending: [(message: String, chatID: TransportChatID)] = []

    public init(
        store: ObservationStore, provider: any LocalModelProvider,
        transport: any MessageTransport, ledger: OutboundLedger,
        chatID: TransportChatID, history: ConversationHistory? = nil
    ) {
        self.store = store
        self.provider = provider
        self.transport = transport
        self.ledger = ledger
        self.defaultChatID = chatID
        self.history = history ?? ConversationHistory()
    }

    /// A nil response means the text is queued; only the final answer is sent.
    public func begin(question: String, to chatID: TransportChatID? = nil) -> String? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 512 else { return "Send a message of at most 512 bytes." }
        guard pending.count < 16 else {
            return "I have too many messages queued. Try again after the current answers arrive."
        }
        pending.append((question, chatID ?? defaultChatID))
        if active == nil { active = Task { await self.drain() } }
        return nil
    }

    public func cancel() {
        pending.removeAll()
        active?.cancel()
    }

    private func drain() async {
        defer { active = nil }
        while !Task.isCancelled && !pending.isEmpty {
            let next = pending.removeFirst()
            await run(message: next.message, to: next.chatID)
        }
    }

    private func run(message: String, to chatID: TransportChatID) async {
        let started = Date()
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
        print("local answer prepared in \\(Int(Date().timeIntervalSince(started) * 1_000))ms for chat \\(chatID.rawValue)")
        let outbound = OutboundTransportMessage(text: reply)
        do {
            try await ledger.begin(requestID: outbound.requestID, chatID: chatID, text: outbound.text)
            // Recipient is fixed by verified host configuration, never model output.
            let receipt = try await transport.send(outbound, to: chatID)
            try await ledger.confirm(requestID: outbound.requestID, messageGUID: receipt.messageGUID)
            try await history.append(user: message, assistant: reply)
            print("local answer submitted (not a delivery confirmation)")
        } catch let failure as TransportFailure where failure.retrySafe {
            try? await ledger.cancel(requestID: outbound.requestID)
            print("chat \\(chatID.rawValue): local answer send did not start")
        } catch {
            try? await ledger.markRecovered(requestID: outbound.requestID)
            print("chat \\(chatID.rawValue): local answer send outcome unknown; no automatic resend")
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
