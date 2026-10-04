import AssistantCore
import Foundation
import LocalInference

public struct EvidenceRetriever: Sendable {
    private let store: ObservationStore
    public init(store: ObservationStore) { self.store = store }

    private static func searchTerms(_ question: String) -> [String] {
        let stopWords: Set<String> = [
            "what", "when", "where", "why", "how", "who", "which", "the", "and", "with",
            "about", "have", "has", "did", "does", "for", "are", "was", "can", "you",
            "tell", "me", "my", "mine", "our", "we", "to", "i", "a", "an", "is", "of",
            "in", "do", "on", "at", "any", "from", "that", "this", "it", "s",
            "today", "tomorrow", "yesterday", "week", "day", "last", "next",
            "message", "messages", "imessage", "sms", "text", "texts", "texted",
            "said", "say", "sent", "send", "told", "replied", "discussed", "decided",
            "agreed", "contact", "contacts", "phone", "number", "email", "address"
        ]
        return Array(question.split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }.filter { !stopWords.contains($0) }.suffix(4))
    }

    private static func search(
        store: ObservationStore, terms: [String],
        sources: Set<ObservationSource> = Set(ObservationSource.allCases)
    ) async throws -> [Observation] {
        guard !terms.isEmpty else { return [] }
        // AND narrows common words before FTS ranking; avoid broad OR scans of the entire index.
        let query = terms.map { "\"\($0)\"" }.joined(separator: " AND ")
        return try await store.search(query, sources: sources, limit: 8).map(\.observation)
    }

    public func request(question: String, meetingPerson: String? = nil, now: Date = Date()) async throws -> EvidenceRequest {
        let normalized = question.lowercased()
        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var observations: [Observation]
        if let meetingPerson {
            let meeting = try await MeetingContextService(store: store, clock: { now }).evidence(for: meetingPerson)
            observations = [meeting.person, meeting.meeting] + Array(meeting.recentMessages.prefix(6))
        } else if !words.isDisjoint(with: ["forgetting", "commitment", "commitments", "promise", "promised"]) {
            observations = []
            for commitment in try await store.openCommitments(limit: 8) {
                if let evidence = try await store.commitmentEvidence(id: commitment.id),
                   !evidence.observation.tombstone,
                   try await store.current(source: .messages, externalID: evidence.observation.externalID)?.id == evidence.observation.id {
                    observations.append(evidence.observation)
                }
            }
        } else if !words.isDisjoint(with: ["sleep", "slept"]) {
            observations = try await store.currentObservations(source: .health, trust: .structuredSource, limit: 2)
        } else if !words.isDisjoint(with: ["calendar", "schedule", "agenda", "meeting", "meetings", "appointment", "appointments", "event", "events", "availability", "plans"]) ||
            (words.contains("my") && !words.isDisjoint(with: ["today", "tomorrow", "week", "day"])) {
            let calendar = Calendar.autoupdatingCurrent
            let start = normalized.contains("tomorrow")
                ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
                : calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: normalized.contains("week") ? 7 : 1, to: start)!
            observations = try await store.currentObservations(source: .calendar, trust: .structuredSource, from: start, to: end.addingTimeInterval(-0.001), limit: 8)
        } else {
            let terms = Self.searchTerms(question)
            if !words.isDisjoint(with: ["contact", "contacts", "phone", "number", "email", "address"]),
               let name = terms.last {
                observations = try await store.search("\"\(name)\"", sources: [.contacts], limit: 8)
                    .map(\.observation)
            } else if !words.isDisjoint(with: ["message", "messages", "imessage", "sms", "text", "texts", "texted", "said", "say", "sent", "send", "told", "replied", "discussed", "decided", "agreed"]) {
                let people: [ObservationSearchHit]
                if let name = terms.last {
                    people = try await store.search("\"\(name)\"", sources: [.contacts], limit: 8)
                } else {
                    people = []
                }
                if people.count == 1, !people[0].observation.handles.isEmpty {
                    observations = try await store.currentObservations(
                        source: .messages,
                        matchingAnyHandle: Set(people[0].observation.handles),
                        limit: 8, newestFirst: true
                    )
                } else {
                    observations = try await Self.search(store: store, terms: terms, sources: [.messages])
                }
            } else {
                observations = try await Self.search(store: store, terms: terms)
            }
        }
        var seen = Set<UUID>()
        observations = observations.filter { seen.insert($0.id).inserted }
        let records = observations.prefix(8).enumerated().map { index, item in
            EvidenceRecord(id: "e\(index + 1)", source: item.source.rawValue, timestamp: item.sourceTimestamp,
                text: EvidenceText.bounded(item.text, bytes: 768), locator: EvidenceText.bounded(item.locator, bytes: 256), trust: item.trust.rawValue)
        }
        var coverage: [String] = []
        if normalized.contains("sleep") || normalized.contains("slept") {
            let formatter = ISO8601DateFormatter()
            coverage.append("Current time: \(formatter.string(from: now)). Sleep summaries cover explicit rolling windows, not a particular night. Describe older collected summaries as snapshots, never as current measurements.")
        }
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
