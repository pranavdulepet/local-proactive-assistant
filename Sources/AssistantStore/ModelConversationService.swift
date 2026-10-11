import AssistantCore
import CryptoKit
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
    private let verbose: Bool
    private let replyPrefix: String
    private let ownerChatIDs: Set<TransportChatID>

    public init(
        store: ObservationStore, provider: any LocalModelProvider,
        transport: any MessageTransport, ledger: OutboundLedger,
        chatID: TransportChatID, history: ConversationHistory? = nil,
        inbox: ConversationInbox? = nil, mail: (any MailSource)? = nil,
        progressDelay: Duration = .seconds(6),
        contextSource: (any ReadContextSource)? = nil,
        contextTools: [ContextTool] = [], verbose: Bool = false, replyPrefix: String = "",
        ownerChatIDs: Set<TransportChatID> = []
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
        self.verbose = verbose
        self.replyPrefix = replyPrefix
        self.ownerChatIDs = ownerChatIDs.isEmpty ? [chatID] : ownerChatIDs
    }

    /// A nil response means the turn is durably queued; slow turns may get progress feedback.
    public func begin(question: String, to chatID: TransportChatID? = nil, sourceID: String? = nil) async throws -> String? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 4_096 else { return "That message is too long. Please split it into shorter texts (up to 4 KB each)." }
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

    /// Re-check local Messages records, never resend. Incoming alias echoes also call this.
    public func reconcilePendingSubmissions() async {
        for turn in await inbox.uncertainTurns() {
            guard let requestID = turn.outboundRequestID else { continue }
            if await ledger.confirmedReceipt(requestID: requestID) != nil {
                try? await inbox.reconcile(requestID: requestID)
                continue
            }
            guard let entry = await ledger.entry(requestID: requestID),
                  let receipt = try? await transport.reconcileSubmission(for: entry, in: ownerChatIDs) else { continue }
            do {
                try await ledger.confirm(requestID: requestID, messageGUID: receipt.messageGUID, rowID: receipt.rowID)
                try await inbox.reconcile(requestID: requestID)
                if verbose { print("Reply observed in local Messages; queue reconciled.") }
            } catch { if verbose { print("Could not save observed submission: \(error)") } }
        }
    }

    public func cancel() async {
        stopping = true
        let running = active
        running?.cancel()
        await running?.value
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
        let readingMailDirectly = contextSource == nil && mail != nil && needsMail
        let progress = ConversationProgress(
            transport: transport, ledger: ledger, chatID: chatID,
            text: replyPrefix + (readingMailDirectly ? "I'm checking Apple Mail on your Mac…" : "I'm working on that…"),
            delay: progressDelay
        )
        await progress.start()
        var reply: String
        var agentMessages: [AgentMessage] = []
        var agentRecords: [EvidenceRecord] = []
        do {
            if let contextSource {
                let answer = try await PersonalContextAgent(
                    provider: provider, source: contextSource, availableTools: contextTools,
                    coverage: [
                        "Current host time: \(ISO8601DateFormatter().string(from: Date())); timezone: \(TimeZone.autoupdatingCurrent.identifier). Relative dates refer to this host clock.",
                        "Each read reports coverage and access errors. Available tools describe host capabilities, not proof of complete access. These reads cannot send or modify source data."
                    ]
                ).reply(message: message, history: await history.recent(),
                    agentHistory: await history.agentTranscript(), previousRecords: await history.agentRecords(),
                    nextRecordID: await history.nextRecordID())
                for entry in answer.trace where verbose {
                    print("local context \(entry.stage) \(entry.tool?.rawValue ?? "model"): \(entry.elapsedMilliseconds)ms; \(entry.outcome)")
                }
                reply = answer.reply.text
                agentMessages = answer.messages
                agentRecords = answer.records
            } else if let agenda = try await CalendarAgendaService(store: store).response(to: message) {
                // The legacy provider has no native tool transcript; keep its exact agenda shortcut.
                reply = agenda
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
                if verbose { print("local retrieval: \(Int(retrievedAt.timeIntervalSince(started) * 1_000))ms; \(request.records.count) records") }
                let chat = ChatRequest(
                    message: message, history: await history.recent(),
                    records: request.records,
                    coverage: ["Host read capabilities: indexed Messages, Calendar, Contacts, \(mail == nil ? "no live Mail adapter" : "Apple Mail Inbox on email requests"), and paired phone sleep summaries. Coverage below describes this turn's available evidence; capability does not imply full access."] + request.coverage
                )
                try chat.validate()
                reply = try await provider.chat(chat).text
                try Task.checkCancellation()
                if verbose { print("local model: \(Int(Date().timeIntervalSince(retrievedAt) * 1_000))ms") }
            }
        } catch is CancellationError {
            await progress.stop()
            return
        } catch let failure as MailSourceFailure {
            reply = failure.description
        } catch let failure as LocalModelFailure {
            reply = failure.description
        } catch {
            if verbose { print("Local conversation failed: \(error)") }
            reply = "The local model couldn't finish this answer. Please try again; if it keeps happening, check the model in the Mac app."
        }
        if Task.isCancelled {
            await progress.stop()
            return
        }
        // Self-chat routes are excluded from Messages ingestion so model replies
        // cannot become source facts. Keep only the owner's raw text searchable.
        do {
            let digest = SHA256.hash(data: Data(message.utf8))
            let locator = "owner-conversation:\(turn.id)"
            _ = try await store.record(Observation(
                source: .messages, externalID: locator,
                versionHash: digest.map { String(format: "%02x", $0) }.joined(),
                sourceRevision: 1, observedAt: turn.acceptedAt, trust: .ownerAuthored,
                text: "Owner message to assistant. Received by host \(ISO8601DateFormatter().string(from: turn.acceptedAt))\n\(message)",
                locator: locator
            ))
        } catch { print("Conversation memory could not be saved locally.") }
        await progress.stop()
        if Task.isCancelled { return }
        if verbose { print("local answer: \(Int(Date().timeIntervalSince(started) * 1_000))ms for chat \(chatID.rawValue)") }
        let outbound = OutboundTransportMessage(text: replyPrefix + reply)
        do {
            try await ledger.begin(requestID: outbound.requestID, chatID: chatID, text: outbound.text)
            // Persist the uncertain-send boundary before calling Messages.
            try await inbox.markSending(turn.id, requestID: outbound.requestID)
        } catch {
            try? await ledger.cancel(requestID: outbound.requestID)
            try? await inbox.mark(turn.id, as: .failed)
            print("chat \(chatID.rawValue): could not persist send intent; no send attempted")
            return
        }
        let receipt: SendReceipt
        do {
            // Recipient is fixed by verified host configuration, never model output.
            receipt = try await transport.send(outbound, to: chatID)
        } catch let failure as TransportFailure where failure.retrySafe {
            try? await ledger.cancel(requestID: outbound.requestID)
            try? await inbox.mark(turn.id, as: .failed)
            print("chat \(chatID.rawValue): local answer send did not start")
            return
        } catch {
            try? await ledger.markRecovered(requestID: outbound.requestID)
            try? await inbox.mark(turn.id, as: .uncertain)
            // The reply may be visible on the phone even when confirmation times out.
            try? await history.append(user: message, assistant: reply, sourceID: turn.id,
                agentMessages: agentMessages, records: agentRecords)
            await reconcilePendingSubmissions()
            if await ledger.confirmedReceipt(requestID: outbound.requestID) == nil {
                print("Reply not yet observed in Messages. Checking locally; it will not be sent twice.")
            } else if verbose { print("Reply observed in local Messages after the send timed out.") }
            return
        }
        // The transport already accepted the send. A local persistence failure
        // cannot turn it into a failed send or cause a second transcript append.
        do { try await ledger.confirm(requestID: outbound.requestID, messageGUID: receipt.messageGUID) }
        catch { print("Reply submitted; its confirmation could not be saved locally.") }
        do { try await inbox.mark(turn.id, as: .submitted) }
        catch { print("Reply submitted; its queue state could not be saved locally. It will not be resent.") }
        do { try await history.append(user: message, assistant: reply, sourceID: turn.id,
            agentMessages: agentMessages, records: agentRecords) }
        catch { print("Reply submitted; conversation history could not be saved locally.") }
        if verbose {
            print("local answer submitted (not a delivery confirmation)")
        } else {
            print("Reply submitted (\(String(format: "%.1f", Date().timeIntervalSince(started)))s).")
        }
    }

}
