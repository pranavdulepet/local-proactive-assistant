import AssistantCore
import Foundation
import LocalInference

/// One foreground question at a time. Generation never holds up the command listener.
public actor ModelConversationService {
    private let store: ObservationStore
    private let provider: any LocalModelProvider
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let chatID: TransportChatID
    private var active: Task<Void, Never>?

    public init(store: ObservationStore, provider: any LocalModelProvider, transport: any MessageTransport, ledger: OutboundLedger, chatID: TransportChatID) {
        self.store = store
        self.provider = provider
        self.transport = transport
        self.ledger = ledger
        self.chatID = chatID
    }

    public func begin(question: String) -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 512 else { return "Ask a question of at most 512 bytes." }
        guard active == nil else { return "A local answer is already in progress. Owner commands still work." }
        active = Task { await self.run(question: question) }
        return "Checking indexed evidence locally. Owner commands still work."
    }

    public func cancel() {
        active?.cancel()
    }

    private func run(question: String) async {
        defer { active = nil }
        do {
            let request = try await EvidenceRetriever(store: store).request(question: question)
            let result = try await AnswerService(provider: provider).answer(request)
            try Task.checkCancellation()
            let message = OutboundTransportMessage(text: result.text)
            try await ledger.begin(requestID: message.requestID, chatID: chatID, text: message.text)
            // The recipient comes from host configuration, never model output. No ambiguous-send retry.
            let receipt = try await transport.send(message, to: chatID)
            try await ledger.confirm(requestID: message.requestID, messageGUID: receipt.messageGUID)
            print("local answer submitted (not a delivery confirmation)")
        } catch is CancellationError {
            return
        } catch {
            print("local answer could not be submitted; check model-status and source-status before asking again")
        }
    }
}
