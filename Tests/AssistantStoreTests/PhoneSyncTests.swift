import AssistantCore
import Foundation
import PhoneSync
import Testing
@testable import AssistantStore

struct PhoneSyncTests {
    @Test
    func phoneUploadBecomesEvidenceAndDisableOrRepairReplacesIt() async throws {
        let store = try ObservationStore()
        let now = Date()
        let device = UUID()
        let summaries = [24, 168].map { hours in
            PhoneSleepDigest(windowHours: hours, start: now.addingTimeInterval(-Double(hours) * 3600),
                end: now, recordedMinutes: hours == 24 ? 420 : 2100, sampleLimitReached: false)
        }
        let envelope = PhoneSyncEnvelope(deviceID: device, sequence: 1, createdAt: now, sleepEnabled: true, sleep: summaries)
        let wire = try PhoneSyncEnvelope.decode(envelope.encode())
        #expect(try await store.acceptPhoneContext(wire) == 1)
        #expect(try await store.acceptPhoneContext(wire) == 1)
        let answer = try await EvidenceRetriever(store: store).request(question: "How much did I sleep?", now: now)
        #expect(answer.records.contains { $0.text.contains("7.0 hours") && $0.source == "health" })
        #expect(answer.coverage.contains { $0.contains("raw samples stay on the phone") })
        let disabled = PhoneSyncEnvelope(deviceID: device, sequence: 2, sleepEnabled: false, sleep: [])
        #expect(try await store.acceptPhoneContext(disabled) == 2)
        #expect(try await EvidenceRetriever(store: store).request(question: "How much did I sleep?").records.isEmpty)
        let repaired = PhoneSyncEnvelope(deviceID: UUID(), sequence: 1, createdAt: now, sleepEnabled: true, sleep: summaries)
        #expect(try await store.acceptPhoneContext(repaired) == 1)
        #expect(try await EvidenceRetriever(store: store).request(question: "How much did I sleep?").records.count == 2)
    }
}
