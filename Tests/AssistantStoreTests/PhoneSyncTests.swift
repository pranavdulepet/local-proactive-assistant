import AssistantCore
import Foundation
import PhoneSync
import Testing
@testable import AssistantStore

struct PhoneSyncTests {
    private func wholeSecondDate(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + offset)
    }

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

    @Test
    func legacyPayloadPreservesOtherSourcesUntilExplicitDisable() async throws {
        let store = try ObservationStore(), device = UUID(), now = wholeSecondDate()
        let activity = PhoneActivityDigest(start: now.addingTimeInterval(-3600), end: now,
            steps: 2300, activeEnergyKilocalories: nil, exerciseMinutes: 12)
        let location = try PhoneLocationDigest.coarsened(latitude: 37.331824, longitude: -122.03118,
            horizontalAccuracyMeters: 30, capturedAt: now, reducedAccuracy: false, now: now)
        _ = try await store.acceptPhoneContext(PhoneSyncEnvelope(deviceID: device, sequence: 1, createdAt: now,
            sleepEnabled: false, sleep: [], activityEnabled: true, activity: activity,
            locationEnabled: true, location: location))
        let firstActivity = try await store.current(source: .health, externalID: "phone-activity:today")
        let firstLocation = try await store.current(source: .location, externalID: "phone-location:coarse")
        // This is the JSON shape produced by the original sleep-only phone, without any new keys.
        let data = Data("""
        {"schemaVersion":"local-assistant.phone.v1","deviceID":"\(device.uuidString)","sequence":2,
         "createdAt":"\(ISO8601DateFormatter().string(from: now))","sleepEnabled":false,"sleep":[]}
        """.utf8)
        let legacy = try PhoneSyncEnvelope.decode(data)
        #expect(legacy.activityEnabled == nil && legacy.locationEnabled == nil)
        #expect(try await store.acceptPhoneContext(legacy) == 2)
        #expect(try await store.current(source: .health, externalID: "phone-activity:today")?.id == firstActivity?.id)
        #expect(try await store.current(source: .location, externalID: "phone-location:coarse")?.id == firstLocation?.id)
        #expect(try await store.sourceCoverage(for: .location)?.lastSuccessfulSync == now)

        _ = try await store.acceptPhoneContext(PhoneSyncEnvelope(deviceID: device, sequence: 3, createdAt: now,
            sleepEnabled: false, sleep: [], activityEnabled: false, locationEnabled: false))
        #expect(try await store.current(source: .health, externalID: "phone-activity:today")?.tombstone == true)
        #expect(try await store.current(source: .location, externalID: "phone-location:coarse")?.tombstone == true)
        #expect(try await store.sourceCoverage(for: .health)?.status == .unavailable)
        #expect(try await store.sourceCoverage(for: .location)?.status == .unavailable)
    }

    @Test
    func delayedUploadRetainsCaptureTimesAndDoesNotConvertUnreadableActivityToZero() async throws {
        let store = try ObservationStore(), captured = wholeSecondDate(-2 * 86400)
        let activity = PhoneActivityDigest(start: captured.addingTimeInterval(-3600), end: captured,
            steps: 0, activeEnergyKilocalories: nil, exerciseMinutes: 0, failedQuantities: [.activeEnergy])
        let fixDate = captured.addingTimeInterval(-60)
        let location = try PhoneLocationDigest.coarsened(latitude: 37.331824, longitude: -122.03118,
            horizontalAccuracyMeters: 1500, capturedAt: fixDate, reducedAccuracy: true, now: captured)
        let envelope = PhoneSyncEnvelope(deviceID: UUID(), sequence: 1, createdAt: captured.addingTimeInterval(20),
            sleepEnabled: false, sleep: [], activityEnabled: true, activity: activity,
            locationEnabled: true, location: location)
        let decoded = try PhoneSyncEnvelope.decode(envelope.encode())
        #expect(decoded == envelope)
        _ = try await store.acceptPhoneContext(decoded)
        let stored = try #require(try await store.current(source: .health, externalID: "phone-activity:today"))
        #expect(stored.sourceTimestamp == captured)
        #expect(stored.text.contains("0 steps"))
        #expect(stored.text.contains("active energy not readable"))
        #expect(stored.text.contains("missing data or denied read access"))
        #expect(!stored.text.contains("0 kcal"))
        #expect(try await store.sourceCoverage(for: .health)?.lastSuccessfulSync == envelope.createdAt)
        #expect(try await store.sourceCoverage(for: .location)?.lastSuccessfulSync == fixDate)
        #expect(try await store.current(source: .location, externalID: "phone-location:coarse")?.sourceTimestamp == fixDate)
        #expect(try await store.search("\"steps\"", sources: [.health], limit: 8).contains { $0.observation.id == stored.id })
    }

    @Test
    func preciseOrStaleCoordinatesAndFailedReadsWithTotalsAreRejected() throws {
        let now = wholeSecondDate()
        #expect(throws: (any Error).self) {
            try PhoneLocationDigest.coarsened(latitude: 37.331824, longitude: -122.03118,
                horizontalAccuracyMeters: 20, capturedAt: now.addingTimeInterval(-901), reducedAccuracy: false, now: now)
        }
        let precise = PhoneLocationDigest(latitude: 37.331824, longitude: -122.03118,
            horizontalAccuracyMeters: 20, capturedAt: now, reducedAccuracy: false)
        #expect(throws: (any Error).self) {
            try PhoneSyncEnvelope(deviceID: UUID(), sequence: 1, createdAt: now,
                sleepEnabled: false, sleep: [], locationEnabled: true, location: precise).encode()
        }
        let badActivity = PhoneActivityDigest(start: now.addingTimeInterval(-3600), end: now,
            steps: 4, activeEnergyKilocalories: nil, exerciseMinutes: nil, failedQuantities: [.steps])
        #expect(throws: (any Error).self) {
            try PhoneSyncEnvelope(deviceID: UUID(), sequence: 1, createdAt: now,
                sleepEnabled: false, sleep: [], activityEnabled: true, activity: badActivity).encode()
        }
    }

    @Test
    func coarseLocationRemovesSmallMovementsAtOrdinaryAndHighLatitudes() throws {
        let now = wholeSecondDate()
        func fix(_ latitude: Double, _ longitude: Double) throws -> PhoneLocationDigest {
            try PhoneLocationDigest.coarsened(latitude: latitude, longitude: longitude,
                horizontalAccuracyMeters: 30, capturedAt: now, reducedAccuracy: false, now: now)
        }
        let first = try fix(37.331824, -122.03118), nearby = try fix(37.331834, -122.03117)
        #expect(first.latitude == nearby.latitude && first.longitude == nearby.longitude)
        #expect(first.latitude != 37.331824 && first.longitude != -122.03118)
        #expect(first.horizontalAccuracyMeters >= 1000)
        // At 80 degrees latitude, a 0.01-degree longitude change is about 190 metres, not a kilometre.
        let northern = try fix(80.002, 10.0), northernNearby = try fix(80.003, 10.01)
        #expect(northern.latitude == northernNearby.latitude && northern.longitude == northernNearby.longitude)
    }

    @Test
    func durableQueuePreservesAdditionalSourcesAcrossRestartAndAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try PhoneUploadQueue(directory: directory), now = wholeSecondDate()
        let pairing = PhonePairing(deviceID: UUID(), name: "Test Mac", server: URL(string: "https://localhost:8765")!,
            certificateSHA256: String(repeating: "a", count: 64), token: String(repeating: "b", count: 64))
        let activity = PhoneActivityDigest(start: now.addingTimeInterval(-3600), end: now,
            steps: nil, activeEnergyKilocalories: nil, exerciseMinutes: nil)
        let location = try PhoneLocationDigest.coarsened(latitude: 37.331824, longitude: -122.03118,
            horizontalAccuracyMeters: 30, capturedAt: now, reducedAccuracy: false, now: now)
        let first = try await queue.enqueue(pairing: pairing, sleepEnabled: false, sleep: [],
            activityEnabled: true, activity: activity, locationEnabled: true, location: location)
        let restored = try PhoneUploadQueue(directory: directory)
        let pending = try await restored.pending()
        #expect(pending.map(\.lastPathComponent) == [first.lastPathComponent])
        let savedFile = try #require(pending.first)
        let saved = try PhoneSyncEnvelope.decode(Data(contentsOf: savedFile))
        #expect(saved.activity == activity && saved.location == location)
        #expect(saved.activity?.steps == nil)
        let second = try await restored.enqueue(pairing: pairing, sleepEnabled: false, sleep: [],
            activityEnabled: false, locationEnabled: false)
        #expect(try PhoneSyncEnvelope.decode(Data(contentsOf: second)).sequence == 2)
        try await restored.acknowledge(saved.sequence)
        let remaining = try await restored.pending()
        #expect(remaining.map(\.lastPathComponent) == [second.lastPathComponent])
        let remainingFile = try #require(remaining.first)
        #expect(try PhoneSyncEnvelope.decode(Data(contentsOf: remainingFile)).sequence == 2)
    }

    @Test
    func repairingTheSameQRPreservesSequenceAndAppliesTheFirstRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try PhoneUploadQueue(directory: directory), store = try ObservationStore(), now = wholeSecondDate()
        let pairing = PhonePairing(deviceID: UUID(), name: "Test Mac", server: URL(string: "https://localhost:8765")!,
            certificateSHA256: String(repeating: "a", count: 64), token: String(repeating: "b", count: 64))
        let activity = PhoneActivityDigest(start: now.addingTimeInterval(-3600), end: now,
            steps: 2300, activeEnergyKilocalories: nil, exerciseMinutes: nil)
        let first = try await queue.enqueue(pairing: pairing, sleepEnabled: false, sleep: [],
            activityEnabled: true, activity: activity)
        let original = try PhoneSyncEnvelope.decode(Data(contentsOf: first))
        let acknowledged = try await store.acceptPhoneContext(original)
        try await queue.acknowledge(acknowledged)

        // Pairing the same QR clears queued payloads, while the Mac keeps its cursor.
        try await queue.reset()
        let restored = try PhoneUploadQueue(directory: directory)
        let next = try await restored.enqueue(pairing: pairing, sleepEnabled: false, sleep: [], activityEnabled: false)
        let revoked = try PhoneSyncEnvelope.decode(Data(contentsOf: next))
        #expect(revoked.sequence == original.sequence + 1)
        // An earlier acknowledgement must not remove this new revocation.
        try await restored.acknowledge(acknowledged)
        let pending = try await restored.pending()
        #expect(pending.map(\.lastPathComponent) == [next.lastPathComponent])
        let pendingFile = try #require(pending.first)
        #expect(try PhoneSyncEnvelope.decode(Data(contentsOf: pendingFile)) == revoked)
        #expect(try await store.acceptPhoneContext(revoked) == revoked.sequence)
        #expect(try await store.current(source: .health, externalID: "phone-activity:today")?.tombstone == true)
    }

    @Test
    func repairingWithALegacyPhoneClearsPreviousDeviceContext() async throws {
        let store = try ObservationStore(), now = wholeSecondDate()
        let activity = PhoneActivityDigest(start: now.addingTimeInterval(-3600), end: now,
            steps: 2300, activeEnergyKilocalories: 60, exerciseMinutes: nil)
        let location = try PhoneLocationDigest.coarsened(latitude: 37.331824, longitude: -122.03118,
            horizontalAccuracyMeters: 30, capturedAt: now, reducedAccuracy: false, now: now)
        _ = try await store.acceptPhoneContext(PhoneSyncEnvelope(deviceID: UUID(), sequence: 5, createdAt: now,
            sleepEnabled: false, sleep: [], activityEnabled: true, activity: activity, locationEnabled: true, location: location))
        _ = try await store.acceptPhoneContext(PhoneSyncEnvelope(deviceID: UUID(), sequence: 1, createdAt: now, sleepEnabled: false, sleep: []))
        #expect(try await store.current(source: .health, externalID: "phone-activity:today")?.tombstone == true)
        #expect(try await store.current(source: .location, externalID: "phone-location:coarse")?.tombstone == true)
    }
}
