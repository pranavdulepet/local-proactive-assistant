import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ControlCommandHandlerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func routesExplicitCommandsAndOrdinaryConversation() async throws {
        let store = try ObservationStore()
        let handler = ControlCommandHandler(store: store, answerQuestion: { "question: \($0)" })
        #expect(try await handler.response(to: "/ask project deadline") == "question: project deadline")
        #expect(try await handler.response(to: "What is the deadline?") == "question: What is the deadline?")
        #expect(try await handler.response(to: "hello") == "question: hello")
        #expect(try await handler.response(to: "/pause")?.contains("paused") == true)
        #expect(try await store.proactivityStatus().paused)
        let disabled = ControlCommandHandler(store: store)
        #expect(try await disabled.response(to: "/ask question")?.contains("disabled") == true)
        #expect(try await disabled.response(to: "/ask") == "Usage: /ask <question>")
    }

    @Test
    func queuedConversationSendsNoImmediateAcknowledgment() async throws {
        let handler = ControlCommandHandler(store: try ObservationStore(), answerQuestion: { _ in nil })
        #expect(try await handler.response(to: "Hello") == nil)
        #expect(try await handler.response(to: "/ask how are you") == nil)
    }

    @Test
    func ignoresOrdinarySelfChatMessages() async throws {
        let handler = ControlCommandHandler(store: try ObservationStore())

        #expect(try await handler.response(to: "note to self") == nil)
    }

    @Test
    func listsOpenCommitmentsWithCoverage() async throws {
        let (store, commitment) = try await fixture()
        let handler = ControlCommandHandler(store: store, clock: { now })

        let response = try #require(
            try await handler.response(to: "What am I forgetting?")
        )

        #expect(response.contains("[\(commitment.id)] overdue"))
        #expect(response.contains(commitment.summary))
        #expect(response.contains("Messages coverage: partial"))
        #expect(response.contains("Coverage limitation: Direct messages only."))
    }

    @Test
    func explainsACommitmentFromStoredEvidence() async throws {
        let (store, commitment) = try await fixture()
        let handler = ControlCommandHandler(store: store, clock: { now })

        let response = try #require(
            try await handler.response(to: "/why \(commitment.id)")
        )

        #expect(response.contains("Why [\(commitment.id)]"))
        #expect(response.contains("Status: active"))
        #expect(response.contains("Conversation: email:alex@example.com"))
        #expect(response.contains("Excerpt: “I’ll send the deck tomorrow”"))
        #expect(response.contains("Source: imsg:message-1"))
    }

    @Test
    func completesACommitmentExplicitly() async throws {
        let (store, commitment) = try await fixture()
        let handler = ControlCommandHandler(store: store, clock: { now })

        #expect(
            try await handler.response(to: "/done \(commitment.id)")
                == "Completed commitment [\(commitment.id)]."
        )
        #expect(try await store.openCommitments().isEmpty)
        #expect(
            try await handler.response(to: "/done \(commitment.id)")
                == "No active commitment found for [\(commitment.id)]."
        )
    }

    @Test
    func returnsUsageForIncompleteOrUnknownCommands() async throws {
        let handler = ControlCommandHandler(store: try ObservationStore())

        #expect(
            try await handler.response(to: "/why")
                == "Usage: /why <commitment-id>"
        )
        #expect(
            try await handler.response(to: "/wat")
                == "Unknown command. Send /help for available commands."
        )
    }

    @Test
    func separateForegroundConnectionSeesRefreshAndUpdatesPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("assistant.sqlite")
        let indexingStore = try ObservationStore(fileURL: databaseURL)
        let foregroundStore = try ObservationStore(fileURL: databaseURL)
        let handler = ControlCommandHandler(store: foregroundStore)

        try await indexingStore.refreshCoverage(
            for: .messages, status: .partial, limitations: [], at: now
        )
        #expect(try await handler.response(to: "/status")?.contains("messages: partial") == true)

        _ = try await handler.response(to: "/resume")
        #expect(try await indexingStore.proactivityStatus().paused == false)
    }

    @Test
    func persistsPauseAndResumeAndReportsPolicy() async throws {
        let store = try ObservationStore()
        let handler = ControlCommandHandler(store: store)
        #expect(try await handler.response(to: "/status")?.contains("paused") == true)
        #expect(try await handler.response(to: "/resume")?.contains("one per day") == true)
        #expect(try await store.proactivityStatus().paused == false)
        #expect(try await handler.response(to: "/pause")?.contains("paused") == true)
        #expect(try await store.proactivityStatus().paused)
        #expect(try await handler.response(to: "/meeting") == "Usage: /meeting <exact person>")
        #expect(try await handler.response(to: "/meeting missing-person")?.contains("No contact exactly matches") == true)
    }

    private func fixture() async throws -> (ObservationStore, CommitmentAssertion) {
        let store = try ObservationStore()
        let sourceDate = now.addingTimeInterval(-86_400)
        let observation = Observation(
            source: .messages,
            externalID: "message-1",
            versionHash: "v1",
            sourceRevision: 1,
            observedAt: sourceDate,
            sourceTimestamp: sourceDate,
            trust: .ownerAuthored,
            handles: ["email:alex@example.com"],
            text: "I’ll send the deck tomorrow",
            locator: "imsg:message-1"
        )
        try await store.record(observation)
        let commitment = CommitmentAssertion(
            id: "commitment-1",
            summary: observation.text,
            dueAt: now.addingTimeInterval(-1),
            dueText: "tomorrow",
            confidence: 1,
            evidenceObservationID: observation.id,
            extractorID: DeterministicCommitmentExtractor.extractorID,
            schemaVersion: DeterministicCommitmentExtractor.schemaVersion,
            createdAt: sourceDate
        )
        try await store.recordCommitments([commitment])
        try await store.refreshCoverage(
            for: .messages,
            status: .partial,
            limitations: ["Direct messages only."],
            at: now
        )
        return (store, commitment)
    }
}
