import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct PersonalContextAgentTests {
    @Test func combinedQuestionMayReadThreeSourcesInItsInitialPlan() async throws {
        let calls = [ContextToolCall(tool: .searchIndex, query: "calendar tomorrow"),
            ContextToolCall(tool: .mailInbox), ContextToolCall(tool: .reminders)]
        let source = AgentSourceFixture(results: Dictionary(uniqueKeysWithValues:
            calls.map { ($0, contextRecord(source: $0.tool.rawValue)) }))
        let provider = AgentModelFixture(plans: [ContextPlan(calls: calls)])
        _ = try await PersonalContextAgent(provider: provider, source: source,
            availableTools: [.searchIndex, .mailInbox, .reminders])
            .reply(message: "Help plan tomorrow using my events, inbox and unfinished tasks", history: [])
        #expect(await source.captured() == calls)
        #expect(await provider.planRequests().count == 1)
        #expect(await provider.chatRequests().first?.records.count == 3)
    }

    @Test func fullSourceSamplesRetainBothCalendarAndMailForCombinedQuestions() async throws {
        let calendar = ContextToolCall(tool: .searchIndex, query: "calendar tomorrow")
        let mail = ContextToolCall(tool: .mailInbox)
        func sample(_ source: String) -> ContextToolResult {
            ContextToolResult(records: (1...8).map { index in
                EvidenceRecord(id: "\(source)-\(index)", source: source, timestamp: nil,
                    text: "\(source) record \(index)", locator: "\(source):\(index)", trust: "unknownExternal")
            }, coverage: ["\(source): eight supplied records."])
        }
        let source = AgentSourceFixture(results: [calendar: sample("calendar"), mail: sample("mail")])
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [calendar, mail])])
        _ = try await PersonalContextAgent(provider: provider, source: source, availableTools: [.searchIndex, .mailInbox])
            .reply(message: "What should I prepare based on tomorrow's events and recent email?", history: [])
        let chat = try #require(await provider.chatRequests().first)
        #expect(chat.records.count == 8)
        #expect(chat.records.filter { $0.source == "calendar" }.count == 4)
        #expect(chat.records.filter { $0.source == "mail" }.count == 4)
        try chat.validate()
    }

    @Test(arguments: [
        ("Anything important come in while I was away?", ContextTool.mailInbox, nil as String?),
        ("What do I need to prepare for after lunch?", .searchIndex, "calendar today afternoon"),
        ("Which items have I left unfinished?", .reminders, nil as String?),
        ("Find the outline I saved for the launch", .notes, "launch outline")
    ])
    func hostFollowsValidatedModelPlanAcrossParaphrases(message: String, tool: ContextTool, query: String?) async throws {
        let call = ContextToolCall(tool: tool, query: query)
        let source = AgentSourceFixture(results: [call: contextRecord(source: tool.rawValue)])
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [call])])
        let agent = PersonalContextAgent(provider: provider, source: source, availableTools: [.mailInbox, .searchIndex, .reminders, .notes])
        let answer = try await agent.reply(message: message, history: [])
        #expect(answer.reply.text == "Based on the supplied context. [e1]")
        #expect(await source.captured() == [call])
        let chat = await provider.chatRequests().first
        #expect(chat?.message == message)
        #expect(chat?.records.first?.source == tool.rawValue)
        #expect(answer.trace.map(\.stage) == ["planning", "read", "reply"])
    }

    @Test func followUpIsPlannedWithHistoryAndEmptyResultCanBeRefined() async throws {
        let first = ContextToolCall(tool: .searchIndex, query: "messages launch")
        let refined = ContextToolCall(tool: .mailInbox, query: "launch")
        let source = AgentSourceFixture(results: [
            first: ContextToolResult(records: [], coverage: ["messages: no matching indexed records"]),
            refined: contextRecord(source: "mail")
        ])
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [first]), ContextPlan(calls: [refined])])
        let history = [ChatTurn(role: .user, text: "Did Maya mention a launch date?"),
            ChatTurn(role: .assistant, text: "I haven't found a matching message.")]
        let agent = PersonalContextAgent(provider: provider, source: source, availableTools: [.searchIndex, .mailInbox])
        _ = try await agent.reply(message: "Could you check somewhere else?", history: history)
        let plans = await provider.planRequests()
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.history == history })
        #expect(plans[1].executedCalls == [first])
        #expect(plans[1].coverage.contains { $0.contains("no matching") })
        #expect(await source.captured() == [first, refined])
    }

    @Test func fileDiscoveryCanBeReadOnSecondPassWithoutDiscardingItsPath() async throws {
        let search = ContextToolCall(tool: .searchFiles, query: "project proposal")
        let read = ContextToolCall(tool: .readFile, path: "/Users/test/Documents/proposal.txt")
        let source = AgentSourceFixture(results: [
            search: contextRecord(source: "files", locator: "/Users/test/Documents/proposal.txt"),
            read: contextRecord(source: "files", locator: "/Users/test/Documents/proposal.txt", text: "Proposal: launch on Friday.")
        ])
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [search]), ContextPlan(calls: [read])])
        _ = try await PersonalContextAgent(provider: provider, source: source, availableTools: [.searchFiles, .readFile])
            .reply(message: "Summarize my project proposal", history: [])
        let plans = await provider.planRequests()
        #expect(plans[1].records.first?.locator == read.path)
        let chat = await provider.chatRequests().first
        #expect(chat?.records.contains { $0.text.contains("launch on Friday") } == true)
        #expect(Set(chat?.records.map(\.id) ?? []).count == chat?.records.count)
    }

    @Test func sourceFailureBecomesCoverageAndDoesNotMasqueradeAsModelFailure() async throws {
        let call = ContextToolCall(tool: .mailInbox)
        let source = AgentSourceFixture(failures: [.mailInbox])
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [call]), ContextPlan(calls: [])])
        let answer = try await PersonalContextAgent(provider: provider, source: source, availableTools: [.mailInbox])
            .reply(message: "Anything urgent in my inbox?", history: [])
        let request = await provider.chatRequests().first
        #expect(request?.coverage.contains { $0.contains("mailInbox: read failed") && $0.contains("permission") } == true)
        #expect(answer.trace.contains { $0.tool == .mailInbox && $0.outcome == "unavailable" })
        #expect(await source.captured() == [call])
    }

    @Test func unsupportedOrInvalidPlansNeverExecuteSources() async throws {
        let source = AgentSourceFixture()
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [ContextToolCall(tool: .readFile, path: "../secret")])])
        await #expect(throws: Error.self) {
            try await PersonalContextAgent(provider: provider, source: source, availableTools: [.readFile])
                .reply(message: "Find the secret", history: [])
        }
        #expect(await source.captured().isEmpty)
        #expect(await provider.chatRequests().isEmpty)
    }

    @Test func threeReadsAndTwoPlanningPassesAreAHardLimit() async throws {
        let a = ContextToolCall(tool: .searchIndex, query: "project plan")
        let b = ContextToolCall(tool: .mailInbox, query: "project")
        let c = ContextToolCall(tool: .notes, query: "project")
        let source = AgentSourceFixture()
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [a, b]), ContextPlan(calls: [c])])
        let answer = try await PersonalContextAgent(provider: provider, source: source, availableTools: [.searchIndex, .mailInbox, .notes])
            .reply(message: "Find the latest project plan", history: [])
        #expect(await source.captured() == [a, b, c])
        #expect(await provider.planRequests().count == 2)
        #expect(answer.trace.filter { $0.stage == "read" }.count == 3)
    }

    @Test func ordinaryConversationDoesNotRequireARead() async throws {
        let source = AgentSourceFixture()
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [])])
        _ = try await PersonalContextAgent(provider: provider, source: source, availableTools: ContextTool.allCases)
            .reply(message: "I've had a rough day. Can we talk?", history: [])
        #expect(await source.captured().isEmpty)
        #expect(await provider.chatRequests().first?.records.isEmpty == true)
    }

    @Test func timedOutSourceIsCancelledAndReportedToFinalModel() async throws {
        let source = AgentSourceFixture(delay: .seconds(5))
        let provider = AgentModelFixture(plans: [ContextPlan(calls: [ContextToolCall(tool: .notes)]), ContextPlan(calls: [])])
        _ = try await PersonalContextAgent(provider: provider, source: source, availableTools: [.notes], readTimeout: .milliseconds(5))
            .reply(message: "Read my notes", history: [])
        let chat = await provider.chatRequests().first
        #expect(chat?.coverage.contains { $0.contains("timed out") } == true)
        #expect(chat?.records.isEmpty == true)
    }
}

private func contextRecord(source: String, locator: String = "fixture:1", text: String = "Relevant private context") -> ContextToolResult {
    ContextToolResult(records: [EvidenceRecord(id: "source-1", source: source, timestamp: nil,
        text: text, locator: locator, trust: "unknownExternal")], coverage: ["\(source): ready; bounded snapshot"])
}

private struct AgentSourceFailure: Error, CustomStringConvertible {
    var description: String { "Allow the requested permission on the Mac." }
}

private actor AgentSourceFixture: ReadContextSource {
    private let results: [ContextToolCall: ContextToolResult]
    private let failures: Set<ContextTool>
    private let delay: Duration?
    private var calls: [ContextToolCall] = []
    init(results: [ContextToolCall: ContextToolResult] = [:], failures: Set<ContextTool> = [], delay: Duration? = nil) {
        self.results = results; self.failures = failures; self.delay = delay
    }
    func execute(_ call: ContextToolCall) async throws -> ContextToolResult {
        calls.append(call)
        if let delay { try await Task.sleep(for: delay) }
        if failures.contains(call.tool) { throw AgentSourceFailure() }
        return results[call] ?? ContextToolResult(records: [], coverage: ["\(call.tool.rawValue): no matching records"])
    }
    func captured() -> [ContextToolCall] { calls }
}

private actor AgentModelFixture: LocalModelProvider {
    nonisolated let modelID = "planned-context-fixture"
    private var plans: [ContextPlan]
    private var requests: [ContextPlanRequest] = []
    private var chats: [ChatRequest] = []
    init(plans: [ContextPlan]) { self.plans = plans }
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "fixture") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer { throw LocalModelFailure("Unexpected evidence answer") }
    func planContext(_ request: ContextPlanRequest) -> ContextPlan {
        requests.append(request)
        return plans.isEmpty ? ContextPlan(calls: []) : plans.removeFirst()
    }
    func chat(_ request: ChatRequest) -> ChatReply {
        chats.append(request)
        return ChatReply(text: "Based on the supplied context. [e1]")
    }
    func planRequests() -> [ContextPlanRequest] { requests }
    func chatRequests() -> [ChatRequest] { chats }
}
