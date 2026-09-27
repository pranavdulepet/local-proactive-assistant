import Foundation
import Testing
@testable import AssistantStore

struct ObservationStoreTests {
    @Test
    func recordsIdempotentlyAndPersists() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("assistant.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let observation = message(
            externalID: "message-1",
            versionHash: "v1",
            text: "I will send the deck this afternoon"
        )
        let store = try ObservationStore(fileURL: fileURL)

        #expect(try await store.record(observation))
        #expect(try await !store.record(observation))

        let reopened = try ObservationStore(fileURL: fileURL)
        let current = try await reopened.current(
            source: .messages,
            externalID: observation.externalID
        )
        let hits = try await reopened.search("deck")

        #expect(current == observation)
        #expect(hits.map(\.observation) == [observation])
    }

    @Test
    func searchReturnsOnlyTheCurrentVersion() async throws {
        let store = try ObservationStore()
        let original = message(
            externalID: "message-1",
            versionHash: "v1",
            text: "Dinner is at Lilia"
        )
        let edited = message(
            externalID: "message-1",
            versionHash: "v2",
            text: "Dinner is at Misi",
            sourceRevision: 2
        )

        try await store.record(original)
        try await store.record(edited)

        let oldHits = try await store.search("Lilia")
        let newHits = try await store.search("Misi")

        #expect(oldHits.isEmpty)
        #expect(newHits.map(\.observation) == [edited])
    }

    @Test
    func olderReplayCannotReplaceTheCurrentVersion() async throws {
        let store = try ObservationStore()
        let older = message(
            externalID: "message-1",
            versionHash: "v1",
            text: "Meet at Lilia"
        )
        let newer = message(
            externalID: "message-1",
            versionHash: "v2",
            text: "Meet at Misi",
            sourceRevision: 2
        )

        try await store.record(newer)
        try await store.record(older)

        let current = try await store.current(
            source: .messages,
            externalID: "message-1"
        )
        let oldHits = try await store.search("Lilia")
        let newHits = try await store.search("Misi")

        #expect(current == newer)
        #expect(oldHits.isEmpty)
        #expect(newHits.map(\.observation) == [newer])
    }

    @Test
    func tombstoneRemovesAnObservationFromSearch() async throws {
        let store = try ObservationStore()
        try await store.record(
            message(
                externalID: "message-1",
                versionHash: "v1",
                text: "Remember the passport"
            )
        )
        let tombstone = message(
            externalID: "message-1",
            versionHash: "deleted-v2",
            text: "",
            sourceRevision: 2,
            tombstone: true
        )

        try await store.record(tombstone)

        let current = try await store.current(
            source: .messages,
            externalID: "message-1"
        )
        let hits = try await store.search("passport")

        #expect(current == tombstone)
        #expect(hits.isEmpty)
    }

    @Test
    func searchCanBeLimitedToSources() async throws {
        let store = try ObservationStore()
        try await store.record(
            message(
                externalID: "message-1",
                versionHash: "v1",
                text: "Project Atlas kickoff"
            )
        )
        let calendar = Observation(
            source: .calendar,
            externalID: "event-1",
            versionHash: "v1",
            sourceRevision: 1,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            trust: .structuredSource,
            text: "Project Atlas review",
            locator: "calendar:event-1"
        )
        try await store.record(calendar)

        let hits = try await store.search("Atlas", sources: [.calendar])

        #expect(hits.map(\.observation) == [calendar])
    }

    @Test
    func recordsAPageAndCursorAtomically() async throws {
        let store = try ObservationStore()
        let valid = message(
            externalID: "message-1",
            versionHash: "v1",
            text: "Remember the passport"
        )
        let invalid = Observation(
            source: .calendar,
            externalID: "event-1",
            versionHash: "v1",
            sourceRevision: 2,
            trust: .structuredSource,
            text: "Dinner",
            locator: "calendar:event-1"
        )

        do {
            try await store.record(
                [valid, invalid],
                advancing: .messages,
                cursor: "42"
            )
            Issue.record("Mixed-source page should fail")
        } catch {
            #expect(try await store.sourceCursor(for: .messages) == nil)
            #expect(
                try await store.current(source: .messages, externalID: valid.externalID) == nil
            )
        }

        let inserted = try await store.record(
            [valid],
            advancing: .messages,
            cursor: "42"
        )

        #expect(inserted == 1)
        #expect(try await store.sourceCursor(for: .messages) == "42")
        #expect(try await store.current(source: .messages, externalID: valid.externalID) == valid)
    }

    private func message(
        externalID: String,
        versionHash: String,
        text: String,
        sourceRevision: Int64 = 1,
        tombstone: Bool = false
    ) -> Observation {
        Observation(
            id: UUID(),
            source: .messages,
            externalID: externalID,
            versionHash: versionHash,
            sourceRevision: sourceRevision,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceTimestamp: Date(timeIntervalSince1970: 1_799_999_000),
            trust: .ownerAuthored,
            text: text,
            locator: "messages:\(externalID)",
            tombstone: tombstone
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
