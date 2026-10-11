import Foundation
import LocalInference
import PhoneContext
import Testing

struct PhoneLocalAssistantTests {
    @Test func injectedOpenProviderKeepsConversationWithoutQuestionSuffixRouting() async throws {
        let provider = PhoneFixtureProvider(replies: ["We can work through that together.", "Let's continue from the earlier message."])
        let assistant = PhoneLocalAssistant(provider: provider)
        _ = try await assistant.answer("I am deciding how to handle a difficult week")
        _ = try await assistant.answer("Can you help me think through the next part?")
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[0].message == "I am deciding how to handle a difficult week")
        #expect(requests[1].history.map(\.role) == [.user, .assistant])
        #expect(requests[1].history.first?.text == requests[0].message)
        #expect(requests.allSatisfy { $0.records.isEmpty })
        #expect(await provider.legacyAnswerCalls == 0)
    }

    @Test func fullUnicodeOwnerMessageReachesInjectedModelAndOversizeIsRejected() async throws {
        let provider = PhoneFixtureProvider(replies: ["I received your full message."])
        let assistant = PhoneLocalAssistant(provider: provider)
        let message = String(repeating: "日", count: 1_000)
        _ = try await assistant.answer(message)
        #expect(await provider.requests.first?.message == message)
        await #expect(throws: LocalModelFailure.self) {
            _ = try await assistant.answer(String(repeating: "日", count: 1_366))
        }
        #expect(await provider.requests.count == 1)
    }

    @Test func rejectedUnsupportedCompletionDoesNotBecomeConversationHistory() async throws {
        let provider = PhoneFixtureProvider(replies: ["I sent your message.", "Let's work through it."])
        let assistant = PhoneLocalAssistant(provider: provider)
        await #expect(throws: ChatReplyFailure.self) { _ = try await assistant.answer("How could I phrase this?") }
        _ = try await assistant.answer("Help me draft it")
        #expect(await provider.requests.last?.history.isEmpty == true)
    }
}

private actor PhoneFixtureProvider: LocalModelProvider {
    nonisolated let modelID = "test-open-phone-model"
    var requests: [ChatRequest] = []
    var legacyAnswerCalls = 0
    private var replies: [String]
    init(replies: [String]) { self.replies = replies }
    func availability() async -> ModelAvailability { .init(ready: true, detail: "Injected phone fixture") }
    func answer(_ request: EvidenceRequest) async throws -> GroundedAnswer {
        legacyAnswerCalls += 1
        return .init(insufficientEvidence: true, claims: [])
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        requests.append(request)
        return ChatReply(text: replies.removeFirst())
    }
}
