import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ControlCommandHandlerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

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
