import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct EvidenceRetrieverTests {
    @Test
    func excludesTombstonesAndBoundsRetrievedText() async throws {
        let store = try ObservationStore()
        let live = Observation(source: .messages, externalID: "live", versionHash: "v1", sourceRevision: 1, trust: .knownExternal, text: "Cedar " + String(repeating: "notes ", count: 500), locator: "imsg:live")
        try await store.record(live)
        try await store.record(Observation(source: .messages, externalID: "gone", versionHash: "v1", sourceRevision: 1, trust: .knownExternal, text: "Cedar secret", locator: "imsg:gone", tombstone: true))
        let request = try await EvidenceRetriever(store: store).request(question: "What about Cedar?")
        #expect(request.records.count == 1)
        #expect(request.records[0].text.utf8.count <= 768)
        #expect(request.records[0].trust == "knownExternal")
        #expect(request.coverage.contains("calendar: never synced."))
        try request.validate()
    }

    @Test
    func naturalMeetingQuestionRetrievesCalendarEvents() async throws {
        let store = try ObservationStore()
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .hour, value: 10,
            to: calendar.date(byAdding: .day, value: 1,
                to: calendar.startOfDay(for: now))!)!
        try await store.record(Observation(
            source: .calendar, externalID: "tomorrow", versionHash: "v1",
            sourceRevision: 1, sourceTimestamp: tomorrow, trust: .structuredSource,
            text: "Team planning at 10 AM", locator: "calendar:tomorrow"
        ))
        let request = try await EvidenceRetriever(store: store).request(
            question: "Do I have any meetings tomorrow?", now: now
        )
        #expect(request.records.map(\.source) == ["calendar"])
        #expect(request.records[0].text.contains("Team planning"))
    }

    @Test
    func personMessageQuestionFollowsContactHandle() async throws {
        let store = try ObservationStore()
        try await store.record(Observation(
            source: .contacts, externalID: "maya", versionHash: "v1",
            sourceRevision: 1, trust: .structuredSource,
            handles: ["maya@example.com"], text: "Maya River\\nEmails: maya@example.com",
            locator: "contacts:maya"
        ))
        try await store.record(Observation(
            source: .messages, externalID: "maya-message", versionHash: "v1",
            sourceRevision: 1, sourceTimestamp: Date(), trust: .knownExternal,
            handles: ["maya@example.com"], text: "Please bring the notes.",
            locator: "imsg:maya-message"
        ))
        try await store.record(Observation(
            source: .messages, externalID: "unrelated", versionHash: "v1",
            sourceRevision: 1, sourceTimestamp: Date(), trust: .knownExternal,
            handles: ["other@example.com"], text: "Unrelated private message.",
            locator: "imsg:unrelated"
        ))
        let request = try await EvidenceRetriever(store: store).request(
            question: "What did Maya text me?"
        )
        #expect(request.records.count == 1)
        #expect(request.records[0].locator == "imsg:maya-message")
    }

    @Test
    func retractedCommitmentEvidenceCannotEnterTheModelContext() async throws {
        let store = try ObservationStore()
        let now = Date()
        let source = Observation(source: .messages, externalID: "source", versionHash: "v1", sourceRevision: 1, sourceTimestamp: now, trust: .ownerAuthored, text: "I will send the notes tonight", locator: "imsg:source")
        try await store.record(source)
        _ = try await CommitmentService(store: store).extractRecent(days: 30)
        try await store.record(Observation(source: .messages, externalID: "source", versionHash: "deleted", sourceRevision: 2, trust: .ownerAuthored, text: "", locator: "imsg:source", tombstone: true))
        let request = try await EvidenceRetriever(store: store).request(question: "What am I forgetting?")
        #expect(request.records.isEmpty)
    }
}
