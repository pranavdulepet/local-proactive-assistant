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
    private let mail: (any MailSource)?
    private let progressDelay: Duration
    private let contextSource: (any ReadContextSource)?
    private let contextTools: [ContextTool]
    private var stopping = false

    public init(
        store: ObservationStore, provider: any LocalModelProvider,
        transport: any MessageTransport, ledger: OutboundLedger,
        chatID: TransportChatID, history: ConversationHistory? = nil,
        inbox: ConversationInbox? = nil, mail: (any MailSource)? = nil,
        progressDelay: Duration = .seconds(2),
        contextSource: (any ReadContextSource)? = nil,
        contextTools: [ContextTool] = []
    ) {
        self.store = store
        self.provider = provider
        self.transport = transport
        self.ledger = ledger
        self.defaultChatID = chatID
        self.history = history ?? ConversationHistory()
        self.inbox = inbox ?? ConversationInbox()
        self.mail = mail
        self.progressDelay = progressDelay
        self.contextSource = contextSource
        self.contextTools = contextTools
    }

    /// A nil response means the turn is durably queued; slow turns may get progress feedback.
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
        let previous = await history.lastUserMessage()
        let query = ConversationContextRouter.retrievalQuery(for: message, previous: previous)
        let needsMail = query.map(ConversationContextRouter.requestsMail) ?? false
        let progress = ConversationProgress(
            transport: transport, ledger: ledger, chatID: chatID,
            text: needsMail ? "I'm checking Apple Mail on your Mac…" : "I'm working on that…",
            delay: progressDelay
        )
        await progress.start()
        var reply: String
        do {
            if let contextSource {
                let answer = try await PersonalContextAgent(
                    provider: provider, source: contextSource, availableTools: contextTools,
                    coverage: [
                        "Current host time: \(ISO8601DateFormatter().string(from: Date())); timezone: \(TimeZone.autoupdatingCurrent.identifier). Relative dates refer to this host clock.",
                        "Each read reports coverage and access errors. Available tools describe host capabilities, not proof of complete access. These reads cannot send or modify source data."
                    ]
                ).reply(message: message, history: await history.recent())
                for entry in answer.trace {
                    print("local context \(entry.stage) \(entry.tool?.rawValue ?? "model"): \(entry.elapsedMilliseconds)ms; \(entry.outcome)")
                }
                reply = answer.reply.text
            } else {
            if needsMail, let mail {
                do { try await MailIngestor(source: mail, store: store).run() }
                catch {
                    try await store.markSourceUnavailable(.mail)
                    throw error
                }
            }
            let request: EvidenceRequest
            if let query {
                request = try await EvidenceRetriever(store: store).request(question: query)
            } else {
                request = EvidenceRequest(question: message, records: [], coverage: [])
            }
            let retrievedAt = Date()
            print("local retrieval prepared in \(Int(retrievedAt.timeIntervalSince(started) * 1_000))ms; \(request.records.count) records")
            let chat = ChatRequest(
                message: message, history: await history.recent(),
                records: request.records,
                coverage: ["Host read capabilities: indexed Messages, Calendar, Contacts, \(mail == nil ? "no live Mail adapter" : "Apple Mail Inbox on email requests"), and paired phone sleep summaries. Coverage below describes this turn's available evidence; capability does not imply full access."] + request.coverage
            )
            try chat.validate()
            reply = try await provider.chat(chat).text
            try Task.checkCancellation()
            print("local model generated in \(Int(Date().timeIntervalSince(retrievedAt) * 1_000))ms")
            }
        } catch is CancellationError {
            await progress.stop()
            return
        } catch let failure as MailSourceFailure {
            reply = failure.description
        } catch {
            reply = "I couldn't answer locally right now. Check model-status on the Mac and try again."
        }
        await progress.stop()
        if Task.isCancelled { return }
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

}
