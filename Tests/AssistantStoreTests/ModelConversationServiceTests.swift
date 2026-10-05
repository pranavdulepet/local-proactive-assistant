import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct ModelConversationServiceTests {
    @Test func exactCalendarAgendaStaysFastAndPersistsFollowUpContext() async throws {
        let store = try ObservationStore()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        try await store.record(Observation(source: .calendar, externalID: "team-sync", versionHash: "v1",
            sourceRevision: 1, sourceTimestamp: tomorrow.addingTimeInterval(3600), trust: .structuredSource,
            text: "Team sync\nStatus: confirmed\nAll day: no", locator: "calendar:team-sync"))
        try await store.refreshCoverage(for: .calendar, status: .partial, limitations: ["Fixture window"], at: now)
        let history = ConversationHistory(), provider = TestChatModel(), transport = AnswerTransport()
        let service = ModelConversationService(store: store, provider: provider, transport: transport,
            ledger: try OutboundLedger(), chatID: TransportChatID(rawValue: 954), history: history)
        let question = "What is on my calendar tomorrow?"
        _ = try await service.begin(question: question, sourceID: "calendar-turn")
        let reply = await transport.waitForSend()
        #expect(reply.0.text.contains("Team sync"))
        for _ in 0..<50 {
            if await history.lastUserMessage() == question { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await history.lastUserMessage() == question)
        #expect(await history.recent().last?.text.contains("Team sync") == true)
        #expect(await provider.captured().isEmpty)
    }

    @Test func transcriptFailureAfterASuccessfulSendDoesNotMakeDeliveryUncertain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let history = try ConversationHistory(fileURL: blocked.appendingPathComponent("history.json"))
        let inbox = ConversationInbox()
        let transport = AnswerTransport()
        let service = ModelConversationService(store: try ObservationStore(), provider: TestChatModel(),
            transport: transport, ledger: try OutboundLedger(), chatID: TransportChatID(rawValue: 954),
            history: history, inbox: inbox)
        _ = try await service.begin(question: "Can you explain how a local model works?", sourceID: "one-turn")
        _ = await transport.waitForSend()
        for _ in 0..<50 {
            if await inbox.counts().queued == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let counts = await inbox.counts()
        #expect(counts.queued == 0 && counts.uncertain == 0 && counts.failed == 0)
        #expect(await history.recent().isEmpty)
        #expect(await transport.sendCount() == 1)
    }

    @Test func conversationQueueUsesModelSelectedSourcesForParaphrasedRequests() async throws {
        let transport = AnswerTransport()
        let source = PlannedNotesFixture()
        let service = ModelConversationService(
            store: try ObservationStore(), provider: PlanningChatFixture(),
            transport: transport, ledger: try OutboundLedger(),
            chatID: TransportChatID(rawValue: 954), contextSource: source,
            contextTools: [.notes]
        )
        #expect(try await service.begin(question: "Find what I wrote about the launch") == nil)
        let sent = await transport.waitForSend()
        #expect(sent.0.text == "Your launch note says Friday. [e1]")
        #expect(await source.count() == 1)
    }

    @Test func ordinaryTextUsesOnDeviceChatAndPersistsRecentTurns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("conversation.json")
        let history = try ConversationHistory(fileURL: historyURL)
        let transport = AnswerTransport()
        let chat = TransportChatID(rawValue: 954)
        let service = ModelConversationService(
            store: try ObservationStore(), provider: TestChatModel(),
            transport: transport, ledger: try OutboundLedger(),
            chatID: chat, history: history
        )
        #expect(try await service.begin(question: "hello") == nil)
        let sent = await transport.waitForSend()
        #expect(sent.1 == chat)
        #expect(sent.0.text == "Hello from the local model.")
        for _ in 0..<50 {
            if await history.lastUserMessage() == "hello" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try ConversationHistory(fileURL: historyURL)
        #expect(await saved.lastUserMessage() == "hello")
        #expect(await saved.recent().count == 2)
    }

    @Test func greetingsAndTranscriptQuestionsUseConversationWithoutIndexedMessages() async throws {
        let store = try ObservationStore()
        try await store.record(Observation(
            source: .messages, externalID: "greeting", versionHash: "v1",
            sourceRevision: 1, observedAt: Date(), trust: .ownerAuthored,
            text: "Hello! This is an unrelated indexed message.", locator: "imsg:greeting"
        ))
        let provider = TestChatModel()
        let transport = AnswerTransport()
        let history = ConversationHistory()
        let service = ModelConversationService(
            store: store, provider: provider, transport: transport,
            ledger: try OutboundLedger(), chatID: TransportChatID(rawValue: 954),
            history: history
        )
        #expect(try await service.begin(question: "Hello!") == nil)
        _ = await transport.waitForSend()
        for _ in 0..<50 {
            if await history.lastUserMessage() == "Hello!" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await service.begin(question: "Tell me what I just said") == nil)
        let second = await transport.waitForSend(count: 2)
        #expect(second.0.text == "Hello from the local model.")
        let requests = await provider.captured()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.records.isEmpty && $0.coverage.count == 1 && $0.coverage[0].contains("Host read capabilities") })
        #expect(requests[1].history.contains { $0.text == "Hello!" })
    }

    @Test func ambiguousDeliveryKeepsContextForTheNextQuestion() async throws {
        let history = ConversationHistory()
        let transport = AnswerTransport(unknownOutcome: true)
        let service = ModelConversationService(
            store: try ObservationStore(), provider: TestChatModel(),
            transport: transport, ledger: try OutboundLedger(),
            chatID: TransportChatID(rawValue: 954), history: history
        )
        #expect(try await service.begin(question: "hello") == nil)
        _ = await transport.waitForSend()
        for _ in 0..<50 {
            if await history.lastUserMessage() == "hello" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await history.recent().map(\.text) == ["hello", "Hello from the local model."])
    }

    @Test func mailRequestsRefreshBeforeCallingTheModel() async throws {
        let provider = TestChatModel()
        let transport = AnswerTransport()
        let source = LiveMailFixture()
        let service = ModelConversationService(
            store: try ObservationStore(), provider: provider,
            transport: transport, ledger: try OutboundLedger(),
            chatID: TransportChatID(rawValue: 954), mail: source
        )
        #expect(try await service.begin(question: "Check my emails") == nil)
        _ = await transport.waitForSend()
        let requests = await provider.captured()
        #expect(requests.count == 1)
        #expect(requests[0].records.first?.source == "mail")
        #expect(requests[0].records.first?.text.contains("Project review") == true)
        #expect(requests[0].coverage.contains { $0.contains("Apple Mail Inbox on email requests") })
    }

    @Test func mailPermissionFailureIsReportedWithoutInventingAnAnswer() async throws {
        let provider = TestChatModel()
        let transport = AnswerTransport()
        let service = ModelConversationService(
            store: try ObservationStore(), provider: provider,
            transport: transport, ledger: try OutboundLedger(),
            chatID: TransportChatID(rawValue: 954), mail: DeniedMailFixture()
        )
        #expect(try await service.begin(question: "Read my inbox") == nil)
        let sent = await transport.waitForSend()
        #expect(sent.0.text == "Allow Automation > Mail and try again.")
        #expect(await provider.captured().isEmpty)
    }

    @Test func slowInferenceKeepsPauseAvailableAndNeverChoosesARecipient() async throws {
        let store = try ObservationStore()
        try await store.record(Observation(source: .messages, externalID: "deadline", versionHash: "v1", sourceRevision: 1, observedAt: Date(), trust: .ownerAuthored, text: "The project deadline is Friday.", locator: "imsg:deadline"))
        let provider = WaitingModel()
        let transport = AnswerTransport()
        let ledger = try OutboundLedger()
        let chat = TransportChatID(rawValue: 955)
        let service = ModelConversationService(store: store, provider: provider, transport: transport, ledger: ledger, chatID: chat)
        #expect(try await service.begin(question: "What did we say about the project?") == nil)
        await provider.waitUntilStarted()
        let secondRoute = TransportChatID(rawValue: 954)
        #expect(try await service.begin(question: "another question", to: secondRoute) == nil)
        let handler = ControlCommandHandler(store: store)
        #expect(try await handler.response(to: "/pause")?.contains("paused") == true)
        #expect(try await store.proactivityStatus().paused)
        await provider.release()
        let sent = await transport.waitForSend()
        #expect(sent.1 == chat)
        #expect(sent.0.text.contains("Friday"))
        #expect(try await ledger.contains(text: sent.0.text, chatID: chat, messageDate: Date()))
        let second = await transport.waitForSend(count: 2)
        #expect(second.1 == secondRoute)
        #expect(second.0.text == "Second answer")
    }
}

private struct LiveMailFixture: MailSource {
    func inboxSnapshot() -> MailSnapshot {
        let record = MailMessageRecord(externalID: "live", sender: "Maya", subject: "Project review", receivedAt: Date(), unread: true, body: "Review at five.")
        return MailSnapshot(messages: [record], totalInbox: 1, scanned: 1)
    }
}

private struct PlanningChatFixture: LocalModelProvider {
    let modelID = "planning-test"
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "ready") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer {
        throw LocalModelFailure("Unexpected structured request")
    }
    func planContext(_ request: ContextPlanRequest) -> ContextPlan {
        ContextPlan(calls: [ContextToolCall(tool: .notes, query: "launch")])
    }
    func chat(_ request: ChatRequest) throws -> ChatReply {
        guard request.records.first?.source == "notes", request.records.first?.text == "Launch on Friday." else {
            throw LocalModelFailure("Missing planned note evidence")
        }
        return ChatReply(text: "Your launch note says Friday. [e1]")
    }
}

private actor PlannedNotesFixture: ReadContextSource {
    private var reads = 0
    func count() -> Int { reads }
    func execute(_ call: ContextToolCall) -> ContextToolResult {
        reads += 1
        return ContextToolResult(records: [EvidenceRecord(
            id: "note", source: "notes", timestamp: nil, text: "Launch on Friday.",
            locator: "notes:test", trust: "unknownExternal"
        )], coverage: ["Notes: one supplied test note."])
    }
}

private struct DeniedMailFixture: MailSource {
    func inboxSnapshot() throws -> MailSnapshot { throw MailSourceFailure("Allow Automation > Mail and try again.") }
}

private actor WaitingModel: LocalModelProvider {
    nonisolated let modelID = "test"
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "test") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer {
        throw LocalModelFailure("Unexpected structured answer request")
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func chat(_ request: ChatRequest) async -> ChatReply {
        if !request.records.isEmpty {
            await withCheckedContinuation { continuation in
                gate = continuation
                started = true
                startedWaiter?.resume()
                startedWaiter = nil
            }
            return ChatReply(text: "The project deadline is Friday. [e1]")
        }
        return ChatReply(text: "Second answer")
    }
}

private actor AnswerTransport: MessageTransport {
    func sendCount() -> Int { sent.count }
    private let unknownOutcome: Bool
    init(unknownOutcome: Bool = false) { self.unknownOutcome = unknownOutcome }
    private var sent: [(OutboundTransportMessage, TransportChatID)] = []
    private var waiters: [(Int, CheckedContinuation<(OutboundTransportMessage, TransportChatID), Never>)] = []
    func probe() -> TransportHealth { TransportHealth(ready: true, detail: "test") }
    func chats() -> [TransportChat] { [] }
    nonisolated func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> { AsyncThrowingStream { $0.finish() } }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) throws -> SendReceipt {
        sent.append((message, chatID))
        for (count, waiter) in waiters where sent.count >= count {
            waiter.resume(returning: sent[count - 1])
        }
        waiters.removeAll { sent.count >= $0.0 }
        if unknownOutcome { throw TransportFailure("send outcome unknown") }
        return SendReceipt(requestID: message.requestID, messageGUID: "test-guid", rowID: 1, transport: "test")
    }
    func waitForSend(count: Int = 1) async -> (OutboundTransportMessage, TransportChatID) {
        if sent.count >= count { return sent[count - 1] }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor TestChatModel: LocalModelProvider {
    nonisolated let modelID = "chat-test"
    private var requests: [ChatRequest] = []
    func captured() -> [ChatRequest] { requests }
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "ready") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer {
        throw LocalModelFailure("Unexpected evidence request")
    }
    func chat(_ request: ChatRequest) throws -> ChatReply {
        requests.append(request)
        return ChatReply(text: "Hello from the local model.")
    }
}
