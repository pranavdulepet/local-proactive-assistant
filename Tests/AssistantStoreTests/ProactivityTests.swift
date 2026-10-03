import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ProactivityTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 21))! }

    @Test
    func defaultsPausedAndEnforcesPersistentBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assistant.sqlite")
        let store = try ObservationStore(fileURL: url)
        try await seed(store)
        #expect(try await store.reserveDueReminder(now: now, calendar: calendar) == nil)
        try await store.setProactivityPaused(false)
        let reservation = try #require(try await store.reserveDueReminder(now: now, calendar: calendar))
        #expect(!reservation.text.contains("private deck"))
        #expect(reservation.text.contains("/why commitment"))
        let reopened = try ObservationStore(fileURL: url)
        #expect(try await reopened.reserveDueReminder(now: now, calendar: calendar) == nil)
        #expect(try await reopened.proactivityStatus().lastGate == "dailyBudget")
        #expect(try await reopened.proactivityStatus().lastDelivery?.contains("reserved") == true)
    }

    @Test
    func completionAndStaleCoveragePreventReservation() async throws {
        let store = try ObservationStore()
        try await seed(store)
        try await store.setProactivityPaused(false)
        try await store.refreshCoverage(for: .messages, status: .partial, limitations: [], at: now.addingTimeInterval(-601))
        #expect(try await store.reserveDueReminder(now: now, calendar: calendar) == nil)
        #expect(try await store.proactivityStatus().lastGate == "staleMessages")
        try await store.refreshCoverage(for: .messages, status: .partial, limitations: [], at: now)
        try await store.completeCommitment(id: "commitment")
        #expect(try await store.reserveDueReminder(now: now, calendar: calendar) == nil)
    }

    @Test
    func rejectsQuietHoursRetractedAndOldEvidence() async throws {
        let store = try ObservationStore()
        let evidence = try await seed(store)
        let coverage = try await store.sourceCoverage(for: .messages)
        #expect(DueCommitmentRule.gate(evidence: evidence, coverage: coverage, currentObservationID: nil, now: now, calendar: calendar) == "retractedEvidence")
        let late = now.addingTimeInterval(3_600)
        try await store.refreshCoverage(for: .messages, status: .partial, limitations: [], at: late)
        #expect(DueCommitmentRule.gate(evidence: evidence, coverage: try await store.sourceCoverage(for: .messages), currentObservationID: evidence.observation.id, now: late, calendar: calendar) == "quietHours")
        #expect(DueCommitmentRule.gate(evidence: evidence, coverage: coverage, currentObservationID: evidence.observation.id, now: now.addingTimeInterval(8 * 86_400), calendar: calendar) == "oldEvidence")
    }

    @Test
    func concurrentReservationsConsumeOneSlot() async throws {
        let store = try ObservationStore()
        try await seed(store)
        try await store.setProactivityPaused(false)
        async let first = store.reserveDueReminder(now: now, calendar: calendar)
        async let second = store.reserveDueReminder(now: now, calendar: calendar)
        let results = try await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
    }

    @discardableResult
    private func seed(_ store: ObservationStore) async throws -> CommitmentEvidence {
        let observation = Observation(source: .messages, externalID: "source-1", versionHash: "v1", sourceRevision: 1, sourceTimestamp: now.addingTimeInterval(-3_600), trust: .ownerAuthored, text: "I will send the private deck tonight", locator: "imsg:source-1")
        try await store.record(observation)
        let commitment = CommitmentAssertion(id: "commitment", summary: observation.text, dueAt: now.addingTimeInterval(7_200), dueText: "tonight", confidence: 1, evidenceObservationID: observation.id, extractorID: DeterministicCommitmentExtractor.extractorID, schemaVersion: DeterministicCommitmentExtractor.schemaVersion, createdAt: now)
        try await store.recordCommitments([commitment])
        try await store.refreshCoverage(for: .messages, status: .partial, limitations: [], at: now)
        return CommitmentEvidence(commitment: commitment, observation: observation)
    }
}
