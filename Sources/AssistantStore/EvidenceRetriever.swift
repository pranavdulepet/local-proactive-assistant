import AssistantCore
import Foundation
import LocalInference

public struct EvidenceRetriever: Sendable {
    private let store: ObservationStore
    public init(store: ObservationStore) { self.store = store }

    public func request(question: String, meetingPerson: String? = nil, now: Date = Date()) async throws -> EvidenceRequest {
        let normalized = question.lowercased()
        var observations: [Observation]
        if let meetingPerson {
            let meeting = try await MeetingContextService(store: store, clock: { now }).evidence(for: meetingPerson)
            observations = [meeting.person, meeting.meeting] + Array(meeting.recentMessages.prefix(6))
        } else if normalized.contains("forgetting") || normalized.contains("commitment") {
            observations = []
            for commitment in try await store.openCommitments(limit: 8) {
                if let evidence = try await store.commitmentEvidence(id: commitment.id),
                   !evidence.observation.tombstone,
                   try await store.current(source: .messages, externalID: evidence.observation.externalID)?.id == evidence.observation.id {
                    observations.append(evidence.observation)
                }
            }
        } else if normalized.contains("calendar") || normalized.contains("schedule") {
            let calendar = Calendar.autoupdatingCurrent
            let start = normalized.contains("tomorrow")
                ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
                : calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: normalized.contains("week") ? 7 : 1, to: start)!
            observations = try await store.currentObservations(source: .calendar, trust: .structuredSource, from: start, to: end.addingTimeInterval(-0.001), limit: 8)
        } else {
            let stopWords: Set<String> = ["what", "when", "where", "why", "how", "the", "and", "with", "about", "have", "did", "does", "for", "are", "was", "can", "you", "tell", "me", "my", "to", "i", "a", "an", "is", "of", "in", "do"]
            let terms = question.split { !$0.isLetter && !$0.isNumber }
                .map { $0.lowercased() }.filter { !stopWords.contains($0) }.prefix(8)
            let query = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
            observations = query.isEmpty ? [] : try await store.search(query, limit: 8).map(\.observation)
        }
        var seen = Set<UUID>()
        observations = observations.filter { seen.insert($0.id).inserted }
        let records = observations.prefix(8).enumerated().map { index, item in
            EvidenceRecord(id: "e\(index + 1)", source: item.source.rawValue, timestamp: item.sourceTimestamp,
                text: EvidenceText.bounded(item.text, bytes: 768), locator: EvidenceText.bounded(item.locator, bytes: 256), trust: item.trust.rawValue)
        }
        var coverage: [String] = []
        for source in ObservationSource.allCases {
            if let state = try await store.sourceCoverage(for: source) {
                let timestamp = ISO8601DateFormatter().string(from: state.lastSuccessfulSync)
                coverage.append(EvidenceText.bounded("\(source.rawValue): \(state.status.rawValue), synced \(timestamp). \(state.limitations.joined(separator: " "))", bytes: 512))
            } else {
                coverage.append("\(source.rawValue): never synced.")
            }
        }
        let request = EvidenceRequest(question: question, createdAt: now, records: Array(records), coverage: coverage)
        try request.validate()
        return request
    }
}
