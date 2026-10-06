import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct NativeConversationTests {
    @Test func dateLookupAndActualToolResultSurviveRestartForFollowUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let history = try ConversationHistory(fileURL: file)
        let tomorrow = ContextToolCall(tool: .calendar, from: "2026-10-07", to: "2026-10-08")
        let nextDay = ContextToolCall(tool: .calendar, from: "2026-10-08", to: "2026-10-09")
        let source = NativeContextFixture()
        let model = NativeConversationFixture(steps: [
            AgentStep(text: "", calls: [AgentToolCall(id: "first-date", call: tomorrow)]),
            AgentStep(text: "Your review is at 10 AM tomorrow. [e1]", calls: [])
        ])
        let first = try await PersonalContextAgent(provider: model, source: source, availableTools: [.calendar])
            .reply(message: "What's on my calendar tomorrow?", history: [])
        try await history.append(user: "What's on my calendar tomorrow?", assistant: first.reply.text,
            sourceID: "first", agentMessages: first.messages, records: first.records)
        let reopened = try ConversationHistory(fileURL: file)
        let followUp = NativeConversationFixture(steps: [
            AgentStep(text: "", calls: [AgentToolCall(id: "second-date", call: nextDay)]),
            AgentStep(text: "The following day has a review too. [e2]", calls: [])
        ])
        _ = try await PersonalContextAgent(provider: followUp, source: source, availableTools: [.calendar])
            .reply(message: "Wb next day", history: await reopened.recent(),
                agentHistory: await reopened.agentTranscript(), previousRecords: await reopened.agentRecords())
        let request = try #require(await followUp.captured().first)
        try request.validate()
        #expect(request.messages.contains { $0.toolCalls.first?.call == tomorrow })
        #expect(request.messages.contains { $0.role == .tool && $0.toolCallID == "first-date" && $0.content.contains("Review") })
        #expect(await source.captured() == [tomorrow, nextDay])
        #expect(await reopened.agentRecords().map(\.id) == ["e1"])
    }

    @Test func ordinaryConversationUsesOneCompletionAndNoPlanningRequest() async throws {
        let model = NativeConversationFixture(steps: [AgentStep(text: "Of course. What happened?", calls: [])])
        let source = NativeContextFixture()
        let answer = try await PersonalContextAgent(provider: model, source: source, availableTools: ContextTool.allCases)
            .reply(message: "I've had a rough day. Can we talk?", history: [])
        #expect(answer.reply.text == "Of course. What happened?")
        #expect(await model.captured().count == 1)
        #expect(await source.captured().isEmpty)
    }

    @Test func modelCorrectsMalformedReadWithoutAskingOwnerToRepeatTheQuestion() async throws {
        let source = NativeContextFixture()
        let model = NativeConversationFixture(steps: [
            AgentStep(text: "", calls: [AgentToolCall(id: "corrected-date",
                call: ContextToolCall(tool: .calendar, from: "2026-10-07", to: "2026-10-08"))]),
            AgentStep(text: "Your review is at 10 AM. [e1]", calls: [])
        ], rejectFirst: true)
        let answer = try await PersonalContextAgent(provider: model, source: source, availableTools: [.calendar])
            .reply(message: "What's on tomorrow?", history: [])
        #expect(answer.reply.text.contains("10 AM"))
        #expect(await model.captured().count == 3)
        #expect(await source.captured().count == 1)
        let corrected = try #require(await model.captured().dropFirst().first)
        #expect(corrected.messages.contains { $0.role == .user && $0.content == "What's on tomorrow?" })
        #expect(corrected.messages.contains { $0.role == .system && $0.content.contains("Host feedback") })
    }

    @Test func uncertainReplyLinkSurvivesRestartAndObservedAliasClearsQueueWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inbox.json")
        let inbox = try ConversationInbox(fileURL: file)
        let requestID = UUID()
        let primary = TransportChatID(rawValue: 955)
        _ = try await inbox.enqueue(id: "question-guid", question: "What is next?", chatID: primary)
        _ = try await inbox.claim()
        try await inbox.markSending("question-guid", requestID: requestID)
        let reopened = try ConversationInbox(fileURL: file)
        let ledger = try OutboundLedger()
        try await ledger.begin(requestID: requestID, chatID: primary, text: "Assistant: Your review is next.")
        let service = ModelConversationService(store: try ObservationStore(),
            provider: NativeConversationFixture(steps: []), transport: ObservedSubmissionFixture(),
            ledger: ledger, chatID: primary, inbox: reopened,
            ownerChatIDs: [primary, TransportChatID(rawValue: 954)])
        await service.reconcilePendingSubmissions()
        #expect(await reopened.counts().uncertain == 0)
        #expect(await ledger.confirmedReceipt(requestID: requestID)?.messageGUID == "actual-message-guid")
    }
}

private actor NativeConversationFixture: LocalModelProvider {
    nonisolated let modelID = "native-conversation-fixture"
    private var steps: [AgentStep]
    private var requests: [AgentRequest] = []
    private var rejectFirst: Bool
    init(steps: [AgentStep], rejectFirst: Bool = false) { self.steps = steps; self.rejectFirst = rejectFirst }
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "fixture") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer { throw LocalModelFailure("Unexpected legacy evidence call") }
    func agentStep(_ request: AgentRequest) throws -> AgentStep {
        requests.append(request)
        if rejectFirst {
            rejectFirst = false
            throw AgentProtocolFailure("Calendar requires explicit from/to dates.")
        }
        guard !steps.isEmpty else { throw LocalModelFailure("Unexpected extra completion") }
        return steps.removeFirst()
    }
    func captured() -> [AgentRequest] { requests }
}

private actor NativeContextFixture: ReadContextSource {
    private var calls: [ContextToolCall] = []
    func execute(_ call: ContextToolCall) -> ContextToolResult {
        calls.append(call)
        return ContextToolResult(records: [EvidenceRecord(id: "temporary", source: "calendar", timestamp: nil,
            text: "Review at 10 AM on " + (call.from ?? "today"), locator: "calendar:review", trust: "structuredSource")],
            coverage: ["Calendar: requested day queried."])
    }
    func captured() -> [ContextToolCall] { calls }
}

private struct ObservedSubmissionFixture: MessageTransport {
    func probe() async -> TransportHealth { TransportHealth(ready: true, detail: "fixture") }
    func chats() async throws -> [TransportChat] { [] }
    func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) async throws -> SendReceipt {
        Issue.record("An observed submission must never be resent")
        throw TransportFailure("Unexpected send")
    }
    func reconcileSubmission(for entry: OutboundLedgerEntry, in verifiedChatIDs: Set<TransportChatID>) async throws -> SendReceipt? {
        #expect(verifiedChatIDs.contains(TransportChatID(rawValue: 954)))
        return SendReceipt(requestID: entry.requestID, messageGUID: "actual-message-guid", rowID: 989069, transport: "applescript-observed")
    }
}
