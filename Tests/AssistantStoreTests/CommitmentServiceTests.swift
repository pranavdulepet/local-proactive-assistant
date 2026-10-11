import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct CommitmentServiceTests {
    @Test
    func extractsRecentOwnerCommitmentsIdempotently() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let store = try ObservationStore()
        let recent = message(
            id: "recent",
            text: "I will send the notes tomorrow",
            date: now.addingTimeInterval(-3_600),
            trust: .ownerAuthored
        )
        let external = message(
            id: "external",
            text: "I will send the notes tomorrow",
            date: now.addingTimeInterval(-1_800),
            trust: .knownExternal
        )
        let old = message(
            id: "old",
            text: "I will send the notes tomorrow",
            date: now.addingTimeInterval(-40 * 86_400),
            trust: .ownerAuthored
        )
        for observation in [recent, external, old] {
            try await store.record(observation)
        }
        let service = CommitmentService(
            store: store,
            extractor: DeterministicCommitmentExtractor(calendar: calendar),
            clock: { now }
        )

        let first = try await service.extractRecent(days: 30)
        let second = try await service.extractRecent(days: 30)

        #expect(first.scanned == 1)
        #expect(first.extracted == 1)
        #expect(first.inserted == 1)
        #expect(first.superseded == 0)
        #expect(second.inserted == 0)
        #expect(second.superseded == 0)
        #expect(try await store.openCommitments().count == 1)
    }

    @Test
    func supersedesActiveResultsThatNoLongerMatchTheExtractor() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try ObservationStore()
        let strong = message(
            id: "strong",
            text: "I will send the notes tomorrow",
            date: now.addingTimeInterval(-3_600),
            trust: .ownerAuthored
        )
        let weak = message(
            id: "weak",
            text: "I will try to leave today",
            date: now.addingTimeInterval(-1_800),
            trust: .ownerAuthored
        )
        for observation in [strong, weak] {
            try await store.record(observation)
            let legacy = CommitmentAssertion(
                id: "v1-\(observation.externalID)",
                summary: observation.text,
                dueAt: now,
                dueText: "today",
                confidence: 1,
                evidenceObservationID: observation.id,
                extractorID: DeterministicCommitmentExtractor.extractorID,
                schemaVersion: "commitment.v1",
                createdAt: observation.sourceTimestamp!
            )
            try await store.recordCommitments([legacy])
        }
        let service = CommitmentService(store: store, clock: { now })

        let summary = try await service.extractRecent(days: 30)

        #expect(summary.extracted == 1)
        #expect(summary.inserted == 1)
        #expect(summary.superseded == 2)
        let open = try await store.openCommitments()
        #expect(open.count == 1)
        #expect(open[0].schemaVersion == "commitment.v2")
        #expect(try await store.commitmentEvidence(id: "v1-strong")?.commitment.status == .superseded)
        #expect(try await store.commitmentEvidence(id: "v1-weak")?.commitment.status == .superseded)
    }

    private func message(
        id: String,
        text: String,
        date: Date,
        trust: ObservationTrust
    ) -> Observation {
        Observation(
            source: .messages,
            externalID: id,
            versionHash: "v1",
            sourceRevision: 1,
            observedAt: date,
            sourceTimestamp: date,
            trust: trust,
            text: text,
            locator: "imsg:\(id)"
        )
    }
}
