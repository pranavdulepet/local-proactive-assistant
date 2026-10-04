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
    private let inbox: ConversationInbox
    private var stopping = false

    public init(
        store: ObservationStore, provider: any LocalModelProvider,
        transport: any MessageTransport, ledger: OutboundLedger,
        chatID: TransportChatID, history: ConversationHistory? = nil,
        inbox: ConversationInbox? = nil
    ) {
        self.store = store
        self.provider = provider
        self.transport = transport
        self.ledger = ledger
        self.defaultChatID = chatID
        self.history = history ?? ConversationHistory()
        self.inbox = inbox ?? ConversationInbox()
    }

    /// A nil response means the turn is durably queued; only the final answer is sent.
    public func begin(question: String, to chatID: TransportChatID? = nil, sourceID: String? = nil) async throws -> String? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 512 else { return "Send a message of at most 512 bytes." }
        let id = sourceID ?? UUID().uuidString
        switch try await inbox.enqueue(id: id, question: question, chatID: chatID ?? defaultChatID) {
        case .accepted, .duplicate:
            await resumePending()
            return nil
        case .full:
            return "I have too many messages queued. Try again after the current answers arrive."
        }
    }

    public func resumePending() async {
        guard !stopping, active == nil, await inbox.hasQueued() else { return }
        active = Task { await self.drain() }
    }

    public func cancel() {
        stopping = true
        active?.cancel()
    }

    private func drain() async {
        var storageFailed = false
        defer {
            active = nil
            if !storageFailed { Task { await self.resumePending() } }
        }
        while !Task.isCancelled {
            let next: ConversationInbox.Turn
            do {
                guard let turn = try await inbox.claim() else { break }
                next = turn
            } catch {
                storageFailed = true
                print("conversation inbox unavailable: \(error)")
                break
            }
            await run(turn: next)
        }
    }

    private func run(turn: ConversationInbox.Turn) async {
        let message = turn.question
        let chatID = turn.chatID
        let started = Date()
        var reply: String
        do {
            if let transcriptReply = Self.transcriptReply(to: message, history: await history.recent()) {
                reply = transcriptReply
            } else {
                let previous = await history.lastUserMessage()
                let request: EvidenceRequest
                if Self.needsPersonalEvidence(message) {
                    let query = Self.retrievalQuery(message, previous: previous)
                    request = try await EvidenceRetriever(store: store).request(question: query)
                } else {
                    // Conversational turns use the recent transcript, not unrelated indexed messages.
                    request = EvidenceRequest(question: message, records: [], coverage: [])
                }
                let retrievedAt = Date()
                print("local retrieval prepared in \(Int(retrievedAt.timeIntervalSince(started) * 1_000))ms; \(request.records.count) records")
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
                print("local model generated in \(Int(Date().timeIntervalSince(retrievedAt) * 1_000))ms")
                }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            reply = "I couldn't answer locally right now. Check model-status on the Mac and try again."
        }
        print("local answer prepared in \(Int(Date().timeIntervalSince(started) * 1_000))ms for chat \(chatID.rawValue)")
        let outbound = OutboundTransportMessage(text: reply)
        do {
            try await ledger.begin(requestID: outbound.requestID, chatID: chatID, text: outbound.text)
            // Persist the uncertain-send boundary before calling Messages.
            try await inbox.mark(turn.id, as: .sending)
        } catch {
            try? await ledger.cancel(requestID: outbound.requestID)
            print("chat \(chatID.rawValue): could not persist send intent; no send attempted")
            return
        }
        do {
            // Recipient is fixed by verified host configuration, never model output.
            let receipt = try await transport.send(outbound, to: chatID)
            try await ledger.confirm(requestID: outbound.requestID, messageGUID: receipt.messageGUID)
            try await inbox.mark(turn.id, as: .submitted)
            try await history.append(user: message, assistant: reply)
            print("local answer submitted (not a delivery confirmation)")
        } catch let failure as TransportFailure where failure.retrySafe {
            try? await ledger.cancel(requestID: outbound.requestID)
            try? await inbox.mark(turn.id, as: .failed)
            print("chat \(chatID.rawValue): local answer send did not start")
        } catch {
            try? await ledger.markRecovered(requestID: outbound.requestID)
            try? await inbox.mark(turn.id, as: .uncertain)
            // The reply may be visible on the phone even when confirmation times out.
            try? await history.append(user: message, assistant: reply)
            print("chat \(chatID.rawValue): local answer send outcome unknown; no automatic resend")
        }
    }

    private static func transcriptReply(to message: String, history: [ChatTurn]) -> String? {
        let words = message.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let plain = words.joined(separator: " ")
        if ["what did i just say", "tell me what i just said", "repeat my last message"].contains(plain) {
            guard let previous = history.last(where: { $0.role == .user })?.text else {
                return "I don't have an earlier message in this conversation."
            }
            return "You said: “\(previous)”"
        }
        if ["what did you just say", "repeat your last answer"].contains(plain) {
            guard let previous = history.last(where: { $0.role == .assistant })?.text else {
                return "I don't have an earlier answer in this conversation."
            }
            return "I said: “\(previous)”"
        }
        return nil
    }

    private static func needsPersonalEvidence(_ message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let plain = words.joined(separator: " ")
        let greetings: Set<String> = [
            "hi", "hello", "hey", "hey there", "good morning", "good afternoon",
            "good evening", "how are you", "how is it going", "thanks", "thank you"
        ]
        if greetings.contains(plain) { return false }
        // These refer to the assistant's small transcript, never the Messages index.
        let transcriptQuestions = [
            "what did i just say", "what i just said", "what did you just say",
            "what you just said", "repeat my last message", "repeat your last answer"
        ]
        return !transcriptQuestions.contains(where: { plain.contains($0) })
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
