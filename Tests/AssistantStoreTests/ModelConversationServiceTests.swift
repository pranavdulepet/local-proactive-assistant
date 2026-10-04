import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct ModelConversationServiceTests {
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
        #expect(await service.begin(question: "hello") == "Let me check.")
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

    @Test func slowInferenceKeepsPauseAvailableAndNeverChoosesARecipient() async throws {
        let store = try ObservationStore()
        try await store.record(Observation(source: .messages, externalID: "deadline", versionHash: "v1", sourceRevision: 1, observedAt: Date(), trust: .ownerAuthored, text: "The project deadline is Friday.", locator: "imsg:deadline"))
        let provider = WaitingModel()
        let transport = AnswerTransport()
        let ledger = try OutboundLedger()
        let chat = TransportChatID(rawValue: 955)
        let service = ModelConversationService(store: store, provider: provider, transport: transport, ledger: ledger, chatID: chat)
        #expect(!(await service.begin(question: "What is the project deadline?")).isEmpty)
        await provider.waitUntilStarted()
        #expect(await service.begin(question: "another question").contains("already in progress"))
        let handler = ControlCommandHandler(store: store)
        #expect(try await handler.response(to: "/pause")?.contains("paused") == true)
        #expect(try await store.proactivityStatus().paused)
        await provider.release()
        let sent = await transport.waitForSend()
        #expect(sent.1 == chat)
        #expect(sent.0.text.contains("Friday"))
        #expect(try await ledger.contains(text: sent.0.text, chatID: chat, messageDate: Date()))
    }
}

private actor WaitingModel: LocalModelProvider {
    nonisolated let modelID = "test"
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "test") }
    func answer(_ request: EvidenceRequest) async throws -> GroundedAnswer {
        await withCheckedContinuation { continuation in
            gate = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
        return GroundedAnswer(insufficientEvidence: false, claims: [GroundedClaim(evidenceIDs: [request.records[0].id], text: "The project deadline is Friday.")])
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

private actor AnswerTransport: MessageTransport {
    private var sent: (OutboundTransportMessage, TransportChatID)?
    private var waiter: CheckedContinuation<(OutboundTransportMessage, TransportChatID), Never>?
    func probe() -> TransportHealth { TransportHealth(ready: true, detail: "test") }
    func chats() -> [TransportChat] { [] }
    nonisolated func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> { AsyncThrowingStream { $0.finish() } }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) -> SendReceipt {
        sent = (message, chatID)
        waiter?.resume(returning: (message, chatID)); waiter = nil
        return SendReceipt(requestID: message.requestID, messageGUID: "test-guid", rowID: 1, transport: "test")
    }
    func waitForSend() async -> (OutboundTransportMessage, TransportChatID) {
        if let sent { return sent }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor TestChatModel: LocalModelProvider {
    nonisolated let modelID = "chat-test"
    func availability() -> ModelAvailability { ModelAvailability(ready: true, detail: "ready") }
    func answer(_ request: EvidenceRequest) throws -> GroundedAnswer {
        throw LocalModelFailure("Unexpected evidence request")
    }
    func chat(_ request: ChatRequest) throws -> ChatReply {
        ChatReply(text: "Hello from the local model.")
    }
}
