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
        #expect(second.inserted == 0)
        #expect(try await store.openCommitments().count == 1)
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
